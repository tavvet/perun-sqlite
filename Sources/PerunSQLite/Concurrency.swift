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

    // MARK: Interrupt / cancellation coordination
    //
    // `sqlite3_interrupt` has to be called from a thread *other* than the one blocked in
    // `sqlite3_step`, so which operation is executing can't be tracked in the connection actor (it
    // is suspended across the blocking call) — it lives here, under a mutex, written on the
    // `ioQueue` around the step and read from the task-cancellation handler.
    //
    // A cancel means one of two things, decided atomically under the lock so there is no gap:
    //   * the operation is executing now  → `sqlite3_interrupt` it (only *that* generation, never a
    //     different concurrent one or a later one that reused the connection);
    //   * the operation is still queued behind other work → record it, so `beginRunning` skips its
    //     body when the queue reaches it (otherwise a cancelled INSERT would still run and commit,
    //     and `withTimeout` would report a timeout for a write that landed).
    //
    // Generations are handed out (`nextGeneration`) and enqueued on the serial `ioQueue` in the same
    // order, so by the time generation G runs, every generation < G has already run — `beginRunning`
    // drops any stale cancellation marks below G, keeping `cancelledGenerations` bounded.
    private let interruptMutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private var generationCounter: UInt64 = 0
    private var runningGeneration: UInt64?
    private var cancelledGenerations: Set<UInt64> = []
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
    /// carries it into `beginRunning`/`cancel`.
    func nextGeneration() -> UInt64 {
        withInterruptLock {
            generationCounter += 1
            return generationCounter
        }
    }

    /// Called on the `ioQueue` immediately before stepping. Returns `false` if this operation's task
    /// was cancelled while it waited its turn on the queue — the caller then skips the body so its
    /// side effects never run; otherwise it becomes the operation now executing. Also drops stale
    /// cancellation marks for generations below this one (they have already run — FIFO order).
    func beginRunning(_ generation: UInt64) -> Bool {
        withInterruptLock {
            let cancelledWhileQueued = cancelledGenerations.remove(generation) != nil
            if !cancelledGenerations.isEmpty {
                cancelledGenerations = cancelledGenerations.filter { $0 > generation }
            }
            if cancelledWhileQueued { return false }
            runningGeneration = generation
            return true
        }
    }

    /// Clear the running marker for `generation`. Call it on the `ioQueue`, immediately after the
    /// step returns — so the window in which a stray interrupt could land on nothing is a couple of
    /// instructions rather than an actor hop.
    func endRunning(_ generation: UInt64) {
        withInterruptLock { if runningGeneration == generation { runningGeneration = nil } }
    }

    /// From the task-cancellation handler. If `generation` is executing now, interrupt it (holding
    /// the lock across `sqlite3_interrupt` so an adjacent operation can't begin or end underneath the
    /// decision); if it is still queued, record it so `beginRunning` skips it. (On SQLite < 3.41 an
    /// interrupt that still races a step's completion by a few instructions can affect the next
    /// statement; ≥ 3.41 it is a no-op.)
    func cancel(_ generation: UInt64) {
        withInterruptLock {
            if runningGeneration == generation {
                if !interruptsDisabled { sqlite3_interrupt(db) }
            } else {
                cancelledGenerations.insert(generation)
            }
        }
    }

    /// Disable interrupts for good. Called on the `ioQueue` just before `sqlite3_close_v2`, so a
    /// cancellation racing the close can never fire `sqlite3_interrupt` on a freed handle.
    func disableInterrupts() {
        withInterruptLock {
            interruptsDisabled = true
            runningGeneration = nil
            cancelledGenerations.removeAll()
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
