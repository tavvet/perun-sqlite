import Dispatch
import CSQLite
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Bridge a blocking libsqlite3 call into async/await.
///
/// The body runs on `queue` (a dedicated, non-cooperative serial dispatch queue), so a blocking
/// `sqlite3_step` — which can wait on a busy lock held by another connection — never parks a
/// thread from the Swift concurrency cooperative pool. This is the direct analogue of
/// perun-pgsql's socket-I/O bridge; SQLite has no socket, but its C calls block all the same.
///
/// Only `Sendable` values cross the boundary: the closure captures the connection's handle
/// through the `@unchecked Sendable` boxes below, and returns a `Sendable` result
/// (`QueryResult`, `[SQLiteValue]`, `Int64`, …).
func withBlockingIO<T: Sendable>(
    on queue: DispatchQueue,
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        queue.async {
            do {
                continuation.resume(returning: try body())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Wraps a non-`Sendable` `sqlite3 *` database handle so the `@Sendable` closures handed to
/// `withBlockingIO` can capture it.
///
/// `@unchecked Sendable` is sound here because every libsqlite3 call for a given connection runs
/// on that connection's single serial `ioQueue`: the actor serializes access to the box, and the
/// queue serializes the C calls, so the pointer is never touched concurrently.
final class SQLiteHandle: @unchecked Sendable {
    let db: OpaquePointer
    /// Set to `true` — on the `ioQueue`, immediately before `sqlite3_close_v2` — once the handle is
    /// closed. Every `ioQueue` block that dereferences `db` checks this first, so the check is
    /// serialized against the close on the same queue: a block enqueued after the close sees
    /// `closed == true` and refuses, and a block enqueued before it ran before the free. This is
    /// what closes the `close()`-vs-in-flight-operation use-after-free window (the actor-side
    /// `isClosed`/`ensureOpen()` guard alone doesn't order against the queued free).
    var closed = false

    // MARK: Interrupt coordination
    //
    // `sqlite3_interrupt` has to be called from a thread *other* than the one blocked in
    // `sqlite3_step`, so which operation is executing can't be tracked in the connection actor (it
    // is suspended across the blocking call) — it lives here, under a mutex, written on the
    // `ioQueue` around the step and read from the task-cancellation handler. Interrupting only the
    // generation that is genuinely running is what stops a cancel from hitting a *different*
    // concurrent operation, or a later one that reused the connection.
    private let interruptMutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private var generationCounter: UInt64 = 0
    private var runningGeneration: UInt64?
    private var interruptsDisabled = false

    init(_ db: OpaquePointer) {
        self.db = db
        pthread_mutex_init(interruptMutex, nil)
    }

    deinit {
        pthread_mutex_destroy(interruptMutex)
        interruptMutex.deallocate()
    }

    @inline(__always)
    private func withInterruptLock<T>(_ body: () -> T) -> T {
        pthread_mutex_lock(interruptMutex)
        defer { pthread_mutex_unlock(interruptMutex) }
        return body()
    }

    /// A fresh, monotonically increasing operation id. Each cancellable operation takes one and
    /// carries it into `beginRunning`/`interruptIfRunning`.
    func nextGeneration() -> UInt64 {
        withInterruptLock {
            generationCounter += 1
            return generationCounter
        }
    }

    /// Mark `generation` as the operation now executing on the `ioQueue`. Call it on the `ioQueue`,
    /// immediately before stepping.
    func beginRunning(_ generation: UInt64) {
        withInterruptLock { runningGeneration = generation }
    }

    /// Clear the running marker for `generation`. Call it on the `ioQueue`, immediately after the
    /// step returns — so the window in which a stray interrupt could land on nothing is a couple of
    /// instructions rather than an actor hop.
    func endRunning(_ generation: UInt64) {
        withInterruptLock { if runningGeneration == generation { runningGeneration = nil } }
    }

    /// Interrupt the connection *iff* `generation` is the operation currently executing — never a
    /// different concurrent one, an already-finished one, or one on a closed handle. The lock is
    /// held across `sqlite3_interrupt` so an adjacent operation can't begin or end underneath the
    /// decision. (On SQLite < 3.41 an interrupt that still races a step's completion by a few
    /// instructions can affect the next statement; ≥ 3.41 it is a no-op.)
    func interruptIfRunning(_ generation: UInt64) {
        withInterruptLock {
            if !interruptsDisabled, runningGeneration == generation {
                sqlite3_interrupt(db)
            }
        }
    }

    /// Disable interrupts for good. Called on the `ioQueue` just before `sqlite3_close_v2`, so a
    /// cancellation racing the close can never fire `sqlite3_interrupt` on a freed handle.
    func disableInterrupts() {
        withInterruptLock {
            interruptsDisabled = true
            runningGeneration = nil
        }
    }
}

/// Wraps a non-`Sendable` `sqlite3_stmt *` for the same reason. `stmt` is `nil` once finalized,
/// so a use-after-finalize is a guarded no-op rather than a dangling-pointer call.
final class StatementHandle: @unchecked Sendable {
    var stmt: OpaquePointer?
    init(_ stmt: OpaquePointer?) { self.stmt = stmt }
}

/// The `SQLITE_TRANSIENT` destructor sentinel: it tells `sqlite3_bind_text`/`_blob` to copy the
/// bytes immediately, so the Swift buffer need not outlive the call. It is a cast macro
/// (`(sqlite3_destructor_type)-1`) the Clang importer can't see, so rebuild it here — the
/// standard idiom in Swift SQLite wrappers.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
