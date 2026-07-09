import Dispatch
import CSQLite

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
    init(_ db: OpaquePointer) { self.db = db }
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
