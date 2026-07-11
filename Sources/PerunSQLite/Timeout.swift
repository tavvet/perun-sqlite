/// Run `operation`, cancelling it and throwing `PerunError.timedOut` if it does not finish within
/// `duration`.
///
/// It races `operation` against a timer and cancels the loser. Because it is built on task
/// cancellation, when `operation` is a query the driver's normal cancellation path runs on a
/// timeout: `sqlite3_interrupt` stops the running statement, `sqlite3_step` returns
/// `SQLITE_INTERRUPT`, and the statement is finalized — so the connection is left reusable before
/// this returns.
///
/// Compose it with anything — a query, an `execute`, a whole `withTransaction`:
///
/// ```swift
/// let rows = try await withTimeout(.seconds(5)) {
///     try await connection.query("SELECT * FROM big_report").rows
/// }
/// ```
///
/// The operation must be cancellation-aware for the timeout to take effect promptly; the driver's
/// query paths are. A non-cancellable operation still runs to completion.
///
/// - Note: like any cancellation, this races the operation's completion. An autocommit write that
///   finishes in the instant the timeout fires may have committed even though `withTimeout` throws
///   `timedOut` — the interrupt lands after the statement is already done. Wrap writes whose
///   landing you must know in a transaction, or re-check the row, rather than assuming a timeout
///   means the write did not happen.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw PerunError.timedOut
        }
        // Whichever finishes first wins; cancel the loser (and let it drain) on the way out.
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
