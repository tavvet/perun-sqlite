/// A pool of SQLite connections.
///
/// `SQLiteClient` lazily opens up to `maxConnections` connections and hands them out one at a
/// time. Callers either grab one with `withConnection` or use the convenience `query` methods,
/// which check a connection out, run, and return it automatically. Each `query` call is its own
/// autocommit unit; use `withTransaction` when several statements must run atomically on one
/// connection.
///
/// ```swift
/// let pool = SQLiteClient(configuration: .file("app.db", journalMode: .wal), maxConnections: 8)
/// let rows = try await pool.query("SELECT * FROM users WHERE id = ?", [id]).rows
/// // …fan out concurrently; the pool hands each task its own connection…
/// await pool.shutdown()
/// ```
///
/// Two SQLite-specific notes on concurrency:
/// - For a file database, set `journalMode: .wal` so multiple pooled connections can read while
///   one writes; in the default rollback-journal mode readers and writers block each other.
/// - A plain `":memory:"` database is *private per connection*, so a pool of them would each see a
///   different, empty database. To share one in-memory database across the pool, use a shared-cache
///   URI: `SQLiteConfiguration(path: "file::memory:?cache=shared", enableURIFilenames: true)`.
public actor SQLiteClient {
    private let configuration: SQLiteConfiguration
    private let maxConnections: Int
    /// Recycle a connection older than this (nil = no limit): bounds connection age.
    private let maxConnectionLifetime: Duration?
    /// Close a connection idle in the pool longer than this (nil = no limit): shrinks the pool
    /// when demand drops.
    private let maxIdleTime: Duration?

    private struct IdleEntry {
        let connection: SQLiteConnection
        let idleSince: ContinuousClock.Instant
    }
    /// Idle, ready-to-use connections, each tagged with when it was returned to the pool.
    private var idle: [IdleEntry] = []
    /// How many connections currently exist (idle + checked out + connecting).
    private var openCount = 0
    /// Tasks parked waiting for a connection to free up.
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<SQLiteConnection, Error>)] = []
    private var nextWaiterID: UInt64 = 0
    private var isShutDown = false
    /// Reaps expired idle connections; started lazily when age-based recycling is enabled.
    private var reaperTask: Task<Void, Never>?

    public init(configuration: SQLiteConfiguration,
                maxConnections: Int = 10,
                maxConnectionLifetime: Duration? = nil,
                maxIdleTime: Duration? = nil) {
        precondition(maxConnections > 0, "maxConnections must be positive")
        self.configuration = configuration
        self.maxConnections = maxConnections
        self.maxConnectionLifetime = maxConnectionLifetime
        self.maxIdleTime = maxIdleTime
    }

    /// Number of connections currently open (idle plus in use).
    public var connectionCount: Int { openCount }

    // MARK: - Running work on a pooled connection

    /// Check out a connection, run `body`, and return the connection to the pool.
    ///
    /// The connection is reused unless the error suggests the handle is in a doubtful state
    /// (corruption, I/O error, an unreadable file), in which case it is discarded and replaced.
    /// SQL errors (constraint violations, type mismatches), decode/local errors and errors thrown
    /// by `body` all leave the connection usable, so it is kept.
    public nonisolated func withConnection<T: Sendable>(
        _ body: (SQLiteConnection) async throws -> T
    ) async throws -> T {
        let connection = try await acquire()
        do {
            let result = try await body(connection)
            await release(connection)
            return result
        } catch {
            await releaseAfterError(connection, error: error)
            throw error
        }
    }

    /// Convenience: run one or more statements (no parameters) on a pooled connection.
    @discardableResult
    public nonisolated func query(_ sql: String) async throws -> QueryResult {
        try await withConnection { try await $0.query(sql) }
    }

    /// Convenience: run a parameterized query on a pooled connection.
    @discardableResult
    public nonisolated func query(_ sql: String,
                                  _ parameters: [(any SQLiteEncodable)?]) async throws -> QueryResult {
        try await withConnection { try await $0.query(sql, parameters) }
    }

    /// Check out one connection, run `body` in a transaction, then return the connection only
    /// after COMMIT or ROLLBACK has completed.
    public nonisolated func withTransaction<T: Sendable>(
        kind: TransactionKind = .deferred,
        _ body: @Sendable (SQLiteConnection.Transaction) async throws -> T
    ) async throws -> T {
        try await withConnection { connection in
            try await connection.withTransaction(kind: kind, body)
        }
    }

    /// Close every connection and fail anyone still waiting. Idempotent.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true

        reaperTask?.cancel()
        reaperTask = nil

        let toClose = idle
        idle.removeAll()
        for entry in toClose {
            try? await entry.connection.close()
        }
        openCount -= toClose.count

        let parked = waiters
        waiters.removeAll()
        for waiter in parked {
            waiter.continuation.resume(throwing: PerunError.clientShutdown)
        }
        // Connections still checked out are closed when they are released.
    }

    // MARK: - Pool internals

    private func acquire() async throws -> SQLiteConnection {
        if isShutDown { throw PerunError.clientShutdown }
        startReaperIfNeeded()

        // Reuse an idle connection, but vet it first: discard one past its age limit and try the
        // next, rather than hand a borrower a connection we mean to recycle.
        while let entry = idle.popLast() {
            if isExpired(entry, now: ContinuousClock().now) {
                openCount -= 1
                Task { try? await entry.connection.close() }
                continue
            }
            let alive = await entry.connection.isProbablyAlive()
            if isShutDown {                        // shutdown raced in during the check
                openCount -= 1
                Task { try? await entry.connection.close() }
                throw PerunError.clientShutdown
            }
            if alive { return entry.connection }
            openCount -= 1                          // closed: drop it and try another
            Task { try? await entry.connection.close() }
        }

        if openCount < maxConnections {
            openCount += 1
            do {
                let connection = try await SQLiteConnection.connect(configuration)
                if isShutDown {
                    try? await connection.close()
                    throw PerunError.clientShutdown
                }
                return connection
            } catch {
                openCount -= 1
                throw error
            }
        }

        // At capacity — wait for a connection to come back. A cancelled waiter must leave the
        // queue and fail, not orphan its continuation and hold its slot.
        let id = nextWaiterID
        nextWaiterID += 1
        let connection = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SQLiteConnection, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // `release()` hands connections off asynchronously w.r.t. cancellation, so a hand-off can
        // win the race after this task was cancelled. Re-check: a cancelled task must not run on a
        // connection it only holds by that race — return it to the pool and fail instead.
        if Task.isCancelled {
            await release(connection)
            throw CancellationError()
        }
        return connection
    }

    /// Drop a cancelled waiter from the queue and fail its `acquire()`. A no-op if a connection was
    /// already handed to it — in that case the resumed `acquire()` re-checks cancellation and
    /// returns the connection to the pool.
    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ connection: SQLiteConnection) async {
        if isShutDown {
            closeDuringShutdown(connection)
            return
        }
        // One hop: finalize any stream the borrower left open past `withConnection` (otherwise its
        // half-stepped SELECT rides along to the next borrower, holding a read snapshot and putting
        // two tasks on one connection), and learn whether the connection is still alive and whether
        // it is mid-transaction.
        let (isAlive, inTransaction) = await connection.prepareForReuse()
        // Re-check: shutdown() may have run — and drained `idle` — while we were suspended on the
        // await above. Without this we would append to an already-torn-down pool and leak the
        // connection.
        if isShutDown {
            closeDuringShutdown(connection)
            return
        }
        // Discard a connection the borrower closed (don't hand a dead handle to a waiter — the
        // acquire() path vets idle connections but a direct hand-off would skip that) or one left
        // mid-transaction.
        guard isAlive, !inTransaction else {
            await discardAndReplaceIfNeeded(connection)
            return
        }
        // Recycle a connection past its lifetime instead of reusing it — including on a direct
        // handoff to a waiter, which otherwise skips the on-borrow age check.
        if let maxLifetime = maxConnectionLifetime,
           ContinuousClock().now - connection.createdAt > maxLifetime {
            await discardAndReplaceIfNeeded(connection)
            return
        }
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: connection)   // hand straight to a waiter
        } else {
            idle.append(IdleEntry(connection: connection, idleSince: ContinuousClock().now))
        }
    }

    private func closeDuringShutdown(_ connection: SQLiteConnection) {
        openCount -= 1
        Task { try? await connection.close() }
    }

    private func releaseAfterError(_ connection: SQLiteConnection, error: Error) async {
        // Only errors that suggest the handle is in a doubtful state require dropping the
        // connection. A SQL error, a decode/local error, or an error from the caller's own closure
        // all leave the connection usable.
        if let perun = error as? PerunError, perun.shouldDiscardConnection {
            await discardAndReplaceIfNeeded(connection)
        } else {
            await release(connection)
        }
    }

    private func discardAndReplaceIfNeeded(_ connection: SQLiteConnection) async {
        openCount -= 1
        try? await connection.close()
        guard !isShutDown, !waiters.isEmpty, openCount < maxConnections else { return }
        let waiter = waiters.removeFirst()
        openCount += 1
        do {
            let replacement = try await SQLiteConnection.connect(configuration)
            if isShutDown {
                openCount -= 1
                try? await replacement.close()
                waiter.continuation.resume(throwing: PerunError.clientShutdown)
                return
            }
            waiter.continuation.resume(returning: replacement)
        } catch {
            openCount -= 1
            waiter.continuation.resume(throwing: error)
        }
    }

    // MARK: - Age-based recycling

    /// Start the background reaper the first time a connection is checked out, when a lifetime or
    /// idle limit is set. Idempotent; cancelled on `shutdown`.
    private func startReaperIfNeeded() {
        guard reaperTask == nil, !isShutDown,
              maxConnectionLifetime != nil || maxIdleTime != nil else { return }
        let interval = reapInterval()
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.reapExpiredIdleConnections()
            }
        }
    }

    /// Scan cadence: about half the smallest limit, but never busier than twice a second.
    private func reapInterval() -> Duration {
        let smallest = [maxIdleTime, maxConnectionLifetime].compactMap { $0 }.min() ?? .seconds(30)
        return max(.milliseconds(500), smallest / 2)
    }

    /// Close every idle connection past a recycling limit and drop it from the pool. The lazy pool
    /// reopens on demand, so there is no minimum idle count to preserve.
    private func reapExpiredIdleConnections() {
        guard !isShutDown else { return }
        let now = ContinuousClock().now
        var kept: [IdleEntry] = []
        kept.reserveCapacity(idle.count)
        for entry in idle {
            if isExpired(entry, now: now) {
                openCount -= 1
                Task { try? await entry.connection.close() }
            } else {
                kept.append(entry)
            }
        }
        idle = kept
    }

    /// Whether an idle connection is past its lifetime (since it was created) or idle limit (since
    /// it was last returned to the pool).
    private func isExpired(_ entry: IdleEntry, now: ContinuousClock.Instant) -> Bool {
        if let maxLifetime = maxConnectionLifetime, now - entry.connection.createdAt > maxLifetime { return true }
        if let maxIdle = maxIdleTime, now - entry.idleSince > maxIdle { return true }
        return false
    }
}
