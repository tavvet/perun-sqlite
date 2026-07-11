import Dispatch
import CSQLite

/// SQLite's rollback-journal / WAL mode, set via `PRAGMA journal_mode`.
public enum JournalMode: String, Sendable {
    case delete, truncate, persist, memory, wal, off
}

/// How a transaction acquires its lock (`BEGIN DEFERRED` / `IMMEDIATE` / `EXCLUSIVE`).
public enum TransactionKind: Sendable, Equatable {
    /// Acquire a lock only when the transaction first reads or writes (the SQLite default).
    case deferred
    /// Acquire a write lock immediately, so a concurrent writer fails fast rather than at COMMIT.
    case immediate
    /// Acquire an exclusive lock immediately (no other connection may read or write).
    case exclusive

    var beginSQL: String {
        switch self {
        case .deferred: return "BEGIN DEFERRED"
        case .immediate: return "BEGIN IMMEDIATE"
        case .exclusive: return "BEGIN EXCLUSIVE"
        }
    }
}

/// Everything needed to open a connection.
///
/// The SQLite analogue of perun-pgsql's `ConnectionConfiguration`: instead of host / port / auth /
/// TLS, it names a database file (or `":memory:"`), open flags, and a few pragmas the driver
/// applies on open.
public struct SQLiteConfiguration: Sendable {
    /// The database file path, `":memory:"` for a private in-memory database, or a URI filename
    /// when `enableURIFilenames` is set.
    public var path: String
    /// Open read-only (`SQLITE_OPEN_READONLY`). When true, `create` is ignored.
    public var readonly: Bool
    /// Create the database file if it does not exist (`SQLITE_OPEN_CREATE`). Ignored when
    /// `readonly`.
    public var create: Bool
    /// Enable foreign-key enforcement (`PRAGMA foreign_keys = ON`) on open. SQLite defaults it
    /// off; this driver defaults it on.
    public var enableForeignKeys: Bool
    /// Set the journal mode (`PRAGMA journal_mode`) on open. `nil` leaves SQLite's default. Use
    /// `.wal` for concurrent readers alongside one writer — the mode that makes a pool useful.
    public var journalMode: JournalMode?
    /// How long a blocked operation waits for a lock before failing with `SQLITE_BUSY`
    /// (`sqlite3_busy_timeout`). `nil` disables the wait (fail immediately). Defaults to 5s.
    public var busyTimeout: Duration?
    /// Interpret `path` as a URI (`SQLITE_OPEN_URI`), enabling `file:…?mode=…&cache=…` filenames —
    /// e.g. `file::memory:?cache=shared` for an in-memory database a pool can share.
    public var enableURIFilenames: Bool
    /// Install data-change hooks (`sqlite3_update_hook`) so row inserts/updates/deletes on this
    /// connection are delivered on `SQLiteConnection.dataChanges`. Off by default — it adds a
    /// callback per changed row.
    public var observeDataChanges: Bool

    public init(path: String,
                readonly: Bool = false,
                create: Bool = true,
                enableForeignKeys: Bool = true,
                journalMode: JournalMode? = nil,
                busyTimeout: Duration? = .seconds(5),
                enableURIFilenames: Bool = false,
                observeDataChanges: Bool = false) {
        self.path = path
        self.readonly = readonly
        self.create = create
        self.enableForeignKeys = enableForeignKeys
        self.journalMode = journalMode
        self.busyTimeout = busyTimeout
        self.enableURIFilenames = enableURIFilenames
        self.observeDataChanges = observeDataChanges
    }

    /// A private, in-memory database that vanishes when the connection closes.
    public static func memory() -> SQLiteConfiguration {
        SQLiteConfiguration(path: ":memory:")
    }

    /// A database backed by a file at `path`.
    public static func file(_ path: String,
                            readonly: Bool = false,
                            create: Bool = true,
                            journalMode: JournalMode? = nil) -> SQLiteConfiguration {
        SQLiteConfiguration(path: path, readonly: readonly, create: create, journalMode: journalMode)
    }

    /// A database addressed by a URI filename (sets `enableURIFilenames`). Use this for a
    /// shared-cache in-memory database that a pool can share across connections:
    /// `.uri("file::memory:?cache=shared")`.
    public static func uri(_ uri: String,
                           readonly: Bool = false,
                           create: Bool = true,
                           journalMode: JournalMode? = nil) -> SQLiteConfiguration {
        SQLiteConfiguration(path: uri, readonly: readonly, create: create,
                            journalMode: journalMode, enableURIFilenames: true)
    }
}

/// A single connection to a SQLite database.
///
/// The connection is an `actor`, so its statement state is isolated — you can hold one from
/// multiple tasks and calls are serialized. Every libsqlite3 call runs on a dedicated serial
/// dispatch queue via `withBlockingIO`, so a blocking `sqlite3_step` (which can wait on a busy
/// lock) never parks a thread from the Swift concurrency cooperative pool.
///
/// A connection serializes its calls but is meant for one logical task at a time: don't fire other
/// queries on the *same* connection while a `withTransaction` or `queryStream` is in progress on
/// it. For concurrency, use `SQLiteClient` (the pool), which hands each task its own connection.
public actor SQLiteConnection {

    /// A scoped transaction running on one connection.
    ///
    /// Use the methods on this value inside `withTransaction`; they run on the connection that owns
    /// the open transaction.
    public struct Transaction: Sendable {
        private let connection: SQLiteConnection
        private let contextID: Int

        fileprivate init(connection: SQLiteConnection, contextID: Int) {
            self.connection = connection
            self.contextID = contextID
        }

        @discardableResult
        public func query(_ sql: String) async throws -> QueryResult {
            try await connection.runTransactionMultiStatement(sql, contextID: contextID)
        }

        @discardableResult
        public func query(_ sql: String,
                          _ parameters: [(any SQLiteEncodable)?]) async throws -> QueryResult {
            try await connection.runTransactionQuery(sql, parameters, contextID: contextID)
        }

        public func prepare(_ sql: String) async throws -> PreparedStatement {
            try await connection.runTransactionPrepare(sql, contextID: contextID)
        }

        @discardableResult
        public func execute(_ statement: PreparedStatement,
                            _ parameters: [(any SQLiteEncodable)?] = []) async throws -> QueryResult {
            try await connection.runTransactionExecute(statement, parameters, contextID: contextID)
        }

        public func closePrepared(_ statement: PreparedStatement) async throws {
            try await connection.runTransactionClosePrepared(statement, contextID: contextID)
        }
    }

    /// The `sqlite3 *` handle, boxed so the `withBlockingIO` closures can capture it. Internal so
    /// the Hooks / Backup / Functions extensions (in other files) can reach it.
    let handle: SQLiteHandle
    /// Every libsqlite3 call for this connection runs here, serially.
    let ioQueue: DispatchQueue
    /// Process-local identity, used to scope prepared-statement handles to their connection.
    let connectionID: UInt64
    /// When this connection was established (monotonic clock), so a pool can recycle it by age.
    /// `nonisolated` so the pool reads it without an actor hop; immutable across checkouts.
    nonisolated let createdAt: ContinuousClock.Instant

    /// Row-change events (`sqlite3_update_hook`), delivered when the configuration set
    /// `observeDataChanges`. Empty otherwise. The SQLite analogue of perun-pgsql's LISTEN/NOTIFY
    /// `notifications` stream — local to this connection rather than a cross-connection channel.
    public nonisolated let dataChanges: AsyncStream<SQLiteChange>
    let changeContinuation: AsyncStream<SQLiteChange>.Continuation
    /// Retains the box the update hook points at; freed after the hook is removed on close.
    var changeHookBox: ChangeHookBox?

    private var isClosed = false

    /// Prepared statements compiled on this connection, keyed by the handle's id.
    private var statements: [UInt64: StatementHandle] = [:]
    private var nextStatementID: UInt64 = 0

    /// Live streams, keyed by generation. Each holds one open `sqlite3_stmt` being stepped.
    private var streams: [UInt64: StreamState] = [:]
    private var streamGeneration: UInt64 = 0

    /// Guards `sqlite3_interrupt` so a cancel fires only against the statement it was meant for,
    /// never a later one that reused the connection.
    private var currentOpGeneration: UInt64 = 0
    private var runningOpGeneration: UInt64?

    /// Transaction context tracking, so a `Transaction` handle can't be used after its scope ends.
    private var transactionContextCounter = 0
    private var activeTransactionContext: Int?

    private struct StreamState {
        let handle: StatementHandle
        let columns: [ColumnMetadata]
    }

    private init(handle: SQLiteHandle,
                 ioQueue: DispatchQueue,
                 connectionID: UInt64,
                 createdAt: ContinuousClock.Instant) {
        self.handle = handle
        self.ioQueue = ioQueue
        self.connectionID = connectionID
        self.createdAt = createdAt
        var continuation: AsyncStream<SQLiteChange>.Continuation!
        self.dataChanges = AsyncStream(bufferingPolicy: .bufferingNewest(1024)) { continuation = $0 }
        self.changeContinuation = continuation
    }

    // MARK: - Opening

    /// Open a connection to the database described by `configuration`.
    public static func connect(_ configuration: SQLiteConfiguration) async throws -> SQLiteConnection {
        let connectionID = nextSQLiteConnectionID()
        let ioQueue = DispatchQueue(label: "perun.sqlite.connection.\(connectionID)")

        let handle: SQLiteHandle = try await withBlockingIO(on: ioQueue) {
            var db: OpaquePointer?
            var flags: Int32 = configuration.readonly
                ? SQLITE_OPEN_READONLY
                : (SQLITE_OPEN_READWRITE | (configuration.create ? SQLITE_OPEN_CREATE : 0))
            if configuration.enableURIFilenames { flags |= SQLITE_OPEN_URI }

            let rc = sqlite3_open_v2(configuration.path, &db, flags, nil)
            guard rc == SQLITE_OK, let db else {
                let message: String
                if let db {
                    message = String(cString: sqlite3_errmsg(db))
                    sqlite3_close_v2(db)
                } else {
                    message = "unable to allocate a database handle"
                }
                throw PerunError.connectionFailed(message)
            }
            sqlite3_extended_result_codes(db, 1)      // so error codes carry the extended detail
            return SQLiteHandle(db)
        }

        let connection = SQLiteConnection(handle: handle,
                                          ioQueue: ioQueue,
                                          connectionID: connectionID,
                                          createdAt: ContinuousClock().now)
        do {
            try await connection.applyConfiguration(configuration)
        } catch {
            try? await connection.close()
            throw error
        }
        return connection
    }

    private func applyConfiguration(_ configuration: SQLiteConfiguration) async throws {
        if let busyTimeout = configuration.busyTimeout {
            let components = busyTimeout.components
            let milliseconds = Int32(clamping: components.seconds * 1000
                                     + components.attoseconds / 1_000_000_000_000_000)
            let db = handle
            _ = try await withBlockingIO(on: ioQueue) { sqlite3_busy_timeout(db.db, milliseconds) }
        }
        if let journalMode = configuration.journalMode {
            _ = try await _runMultiStatement("PRAGMA journal_mode = \(journalMode.rawValue)")
        }
        if configuration.enableForeignKeys {
            _ = try await _runMultiStatement("PRAGMA foreign_keys = ON")
        }
        if configuration.observeDataChanges {
            await installChangeHooks()
        }
    }

    // MARK: - Introspection

    /// Whether the connection is currently inside an open transaction (`sqlite3_get_autocommit`).
    /// Returns `false` on a closed connection.
    public var isInTransaction: Bool {
        get async {
            if isClosed { return false }
            let db = handle
            return (try? await withBlockingIO(on: ioQueue) {
                guard !db.closed else { throw PerunError.connectionClosed }
                return sqlite3_get_autocommit(db.db) == 0
            }) ?? false
        }
    }

    /// The rowid of the most recent successful `INSERT` on this connection. `0` if closed.
    public var lastInsertRowID: Int64 {
        get async {
            if isClosed { return 0 }
            let db = handle
            return (try? await withBlockingIO(on: ioQueue) {
                guard !db.closed else { throw PerunError.connectionClosed }
                return sqlite3_last_insert_rowid(db.db)
            }) ?? 0
        }
    }

    /// Rows changed by the most recent statement (`sqlite3_changes`). `0` if closed.
    public var changes: Int {
        get async {
            if isClosed { return 0 }
            let db = handle
            return (try? await withBlockingIO(on: ioQueue) {
                guard !db.closed else { throw PerunError.connectionClosed }
                return Int(sqlite3_changes(db.db))
            }) ?? 0
        }
    }

    /// Rows changed by all statements since the connection opened (`sqlite3_total_changes`). `0` if
    /// closed.
    public var totalChanges: Int {
        get async {
            if isClosed { return 0 }
            let db = handle
            return (try? await withBlockingIO(on: ioQueue) {
                guard !db.closed else { throw PerunError.connectionClosed }
                return Int(sqlite3_total_changes(db.db))
            }) ?? 0
        }
    }

    /// Ask SQLite to abort the statement currently running on this connection
    /// (`sqlite3_interrupt`). Best-effort — it races the statement.
    public func interrupt() {
        guard !isClosed else { return }
        sqlite3_interrupt(handle.db)
    }

    /// A pool liveness check. A SQLite connection doesn't die on its own, so this is just "not
    /// closed" — the analogue of perun-pgsql's socket probe.
    func isProbablyAlive() async -> Bool { !isClosed }

    // MARK: - Queries

    /// Run one or more SQL statements with no bound parameters, returning the last result set.
    ///
    /// Like `sqlite3_exec`, the `sql` string may hold several statements separated by `;`. Each
    /// runs in autocommit (no implicit transaction across them); wrap them in `withTransaction`
    /// for atomicity.
    @discardableResult
    public func query(_ sql: String) async throws -> QueryResult {
        try ensureOpen()
        return try await _runMultiStatement(sql)
    }

    /// Run a single parameterized statement. Parameters bind positionally to `?` placeholders
    /// (`?1…?n`); a `nil` element is SQL NULL.
    @discardableResult
    public func query(_ sql: String,
                      _ parameters: [(any SQLiteEncodable)?]) async throws -> QueryResult {
        try ensureOpen()
        return try await _runSingleStatement(sql, parameters)
    }

    /// Stream a query's rows lazily instead of buffering them. See `SQLiteRowStream`.
    public func queryStream(_ sql: String,
                            _ parameters: [(any SQLiteEncodable)?] = []) async throws -> SQLiteRowStream {
        try ensureOpen()
        streamGeneration += 1
        let generation = streamGeneration
        let db = handle
        let boundParameters = parameters

        let prepared: (handle: StatementHandle, columns: [ColumnMetadata]) =
            try await withBlockingIO(on: ioQueue) {
                guard !db.closed else { throw PerunError.connectionClosed }
                let stmt = try perunCompileSingle(sql, db: db.db)
                do {
                    try perunBindParameters(boundParameters, to: stmt, db: db.db)
                } catch {
                    sqlite3_finalize(stmt)
                    throw error
                }
                return (StatementHandle(stmt), perunColumnMetadata(stmt))
            }

        streams[generation] = StreamState(handle: prepared.handle, columns: prepared.columns)
        return SQLiteRowStream(connection: self, generation: generation)
    }

    /// Compile a statement for repeated execution.
    ///
    /// The compiled statement lives on the connection until you `closePrepared` it (or the
    /// connection closes). Call `closePrepared` when done — especially before returning a pooled
    /// connection, so the compiled statement doesn't ride along to the next borrower.
    public func prepare(_ sql: String) async throws -> PreparedStatement {
        try ensureOpen()
        return try await _prepare(sql)
    }

    /// Run a prepared statement with a fresh set of parameters.
    @discardableResult
    public func execute(_ statement: PreparedStatement,
                        _ parameters: [(any SQLiteEncodable)?] = []) async throws -> QueryResult {
        try ensureOpen()
        return try await _execute(statement, parameters)
    }

    /// Finalize a prepared statement, releasing its compiled form.
    public func closePrepared(_ statement: PreparedStatement) async throws {
        try ensureOpen()
        try await _closePrepared(statement)
    }

    // MARK: - Transactions

    /// Run `body` inside a SQL transaction. `BEGIN` runs first; `COMMIT` on success, `ROLLBACK` if
    /// `body` throws. Transaction control (BEGIN/COMMIT/ROLLBACK) runs uninterruptibly, so a
    /// timed-out transaction still rolls back cleanly rather than leaving one open.
    ///
    /// SQLite can roll a transaction back on its own — an `ON CONFLICT ROLLBACK` clause, or a fatal
    /// error like `SQLITE_FULL`. If that happens mid-`body` and `body` swallows the error, the
    /// remaining statements would otherwise run in autocommit and persist one at a time, quietly
    /// breaking atomicity. To prevent that, each statement checks the transaction is still open
    /// first, and `throw`s `PerunError.transactionRolledBack` once it is gone.
    ///
    /// SQLite has no nested transactions, so calling this again on the same connection while a
    /// transaction is open throws (its `BEGIN` is rejected) — but the outer transaction's context
    /// is saved and restored, so it stays usable afterward. Use `SAVEPOINT` SQL if you need nesting.
    ///
    /// If the closing `ROLLBACK` itself fails (rare — on modern SQLite a pending read no longer
    /// blocks it), the connection may remain inside the aborted transaction. The pool discards such
    /// a connection on release (it checks `isInTransaction`); a directly held connection should not
    /// be reused until the transaction is resolved.
    public func withTransaction<T: Sendable>(
        kind: TransactionKind = .deferred,
        _ body: @Sendable (Transaction) async throws -> T
    ) async throws -> T {
        try ensureOpen()
        let previousContext = activeTransactionContext
        transactionContextCounter += 1
        let contextID = transactionContextCounter
        activeTransactionContext = contextID
        defer { activeTransactionContext = previousContext }

        try await _execUninterruptible(kind.beginSQL)
        do {
            let result = try await body(Transaction(connection: self, contextID: contextID))
            // If SQLite auto-rolled-back the transaction under us (and `body` swallowed the error),
            // there is nothing to commit; committing now would be a no-op that hides the break.
            guard try await currentlyInTransaction() else {
                throw PerunError.transactionRolledBack
            }
            try await _execUninterruptible("COMMIT")
            return result
        } catch {
            try? await _execUninterruptible("ROLLBACK")
            throw error
        }
    }

    private func validateTransactionContext(_ contextID: Int) throws {
        guard activeTransactionContext == contextID else {
            throw PerunError.invalidTransactionContext
        }
    }

    /// Whether the connection is currently inside an open transaction (`sqlite3_get_autocommit`),
    /// throwing rather than swallowing a closed-handle error (unlike the public `isInTransaction`).
    private func currentlyInTransaction() async throws -> Bool {
        let db = handle
        return try await withBlockingIO(on: ioQueue) {
            guard !db.closed else { throw PerunError.connectionClosed }
            return sqlite3_get_autocommit(db.db) == 0
        }
    }

    /// Validate the transaction context, then confirm SQLite has not rolled the transaction back
    /// on its own. Guards every statement run through a `Transaction`, so a statement after an
    /// auto-rollback fails loudly instead of committing in autocommit.
    private func ensureTransactionActive(_ contextID: Int) async throws {
        try validateTransactionContext(contextID)
        guard try await currentlyInTransaction() else {
            throw PerunError.transactionRolledBack
        }
    }

    private func runTransactionMultiStatement(_ sql: String, contextID: Int) async throws -> QueryResult {
        try await ensureTransactionActive(contextID)
        return try await _runMultiStatement(sql)
    }

    private func runTransactionQuery(_ sql: String,
                                     _ parameters: [(any SQLiteEncodable)?],
                                     contextID: Int) async throws -> QueryResult {
        try await ensureTransactionActive(contextID)
        return try await _runSingleStatement(sql, parameters)
    }

    private func runTransactionPrepare(_ sql: String, contextID: Int) async throws -> PreparedStatement {
        try validateTransactionContext(contextID)
        return try await _prepare(sql)
    }

    private func runTransactionExecute(_ statement: PreparedStatement,
                                       _ parameters: [(any SQLiteEncodable)?],
                                       contextID: Int) async throws -> QueryResult {
        try await ensureTransactionActive(contextID)
        return try await _execute(statement, parameters)
    }

    private func runTransactionClosePrepared(_ statement: PreparedStatement, contextID: Int) async throws {
        try validateTransactionContext(contextID)
        try await _closePrepared(statement)
    }

    // MARK: - Closing

    /// Finalize every prepared statement and stream, then close the database handle. Idempotent.
    public func close() async throws {
        guard !isClosed else { return }
        isClosed = true

        let statementHandles = Array(statements.values)
        statements.removeAll()
        let streamHandles = streams.values.map(\.handle)
        streams.removeAll()
        let db = handle
        let hadChangeHook = changeHookBox != nil

        _ = try? await withBlockingIO(on: ioQueue) {
            // Remove the update hook before the box it points at is freed below.
            if hadChangeHook { sqlite3_update_hook(db.db, nil, nil) }
            for handle in statementHandles where handle.stmt != nil {
                sqlite3_finalize(handle.stmt)
                handle.stmt = nil
            }
            for handle in streamHandles where handle.stmt != nil {
                sqlite3_finalize(handle.stmt)
                handle.stmt = nil
            }
            db.closed = true       // block any later ioQueue op before we free the handle
            sqlite3_close_v2(db.db)
            return ()
        }
        changeContinuation.finish()
        changeHookBox = nil        // hook removed above; safe to release the box
    }

    /// Safety net for a connection dropped without `close()`: free the handle, its statements, and
    /// the change-hook on the `ioQueue` so a forgotten connection (or a pool dropped without
    /// `shutdown()`) doesn't leak the `sqlite3 *`, its file descriptor, or compiled statements.
    /// Mirrors perun-pgsql's `PostgresConnection` deinit. At deinit there are no other references,
    /// so no in-flight operation can race this.
    deinit {
        guard !isClosed else { return }
        let statementHandles = Array(statements.values) + streams.values.map(\.handle)
        let db = handle
        let hadChangeHook = changeHookBox != nil
        changeContinuation.finish()
        ioQueue.async {
            if hadChangeHook { sqlite3_update_hook(db.db, nil, nil) }
            for handle in statementHandles where handle.stmt != nil {
                sqlite3_finalize(handle.stmt)
                handle.stmt = nil
            }
            db.closed = true
            sqlite3_close_v2(db.db)
        }
    }

    // MARK: - Streaming internals

    func nextStreamRow(generation: UInt64) async throws -> SQLiteRow? {
        guard let state = streams[generation] else { return nil }
        let statementHandle = state.handle
        let columns = state.columns
        let columnCount = Int32(columns.count)
        let db = handle

        currentOpGeneration += 1
        let operationGeneration = currentOpGeneration
        runningOpGeneration = operationGeneration
        defer { if runningOpGeneration == operationGeneration { runningOpGeneration = nil } }

        let outcome: Result<[SQLiteValue]?, Error> = await withTaskCancellationHandler {
            do {
                let row: [SQLiteValue]? = try await withBlockingIO(on: ioQueue) {
                    guard let stmt = statementHandle.stmt else { return nil }
                    switch sqlite3_step(stmt) {
                    case SQLITE_ROW: return perunReadRow(stmt, columnCount)
                    case SQLITE_DONE: return nil
                    default: throw perunSQLiteError(db.db)
                    }
                }
                return .success(row)
            } catch {
                return .failure(error)
            }
        } onCancel: {
            Task { await self.interruptIfRunning(generation: operationGeneration) }
        }

        if Task.isCancelled {
            await finishStream(generation: generation)
            throw CancellationError()
        }

        switch outcome {
        case let .success(row):
            if let values = row {
                return SQLiteRow(values: values, columns: columns)
            }
            await finishStream(generation: generation)      // SQLITE_DONE
            return nil
        case let .failure(error):
            await finishStream(generation: generation)
            throw error
        }
    }

    func finishStream(generation: UInt64) async {
        guard let state = streams.removeValue(forKey: generation) else { return }
        let statementHandle = state.handle
        _ = try? await withBlockingIO(on: ioQueue) {
            if let stmt = statementHandle.stmt {
                sqlite3_finalize(stmt)
                statementHandle.stmt = nil
            }
            return ()
        }
    }

    // MARK: - Cancellation

    /// Run a cancellable blocking operation: a cancel fires `sqlite3_interrupt` so a blocked
    /// `sqlite3_step` unblocks and returns `SQLITE_INTERRUPT`, and the caller sees
    /// `CancellationError`. The generation guard stops a late cancel from hitting a later
    /// operation on the same connection. This is what makes `withTimeout` stop a query promptly.
    private func runCancellable<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        currentOpGeneration += 1
        let operationGeneration = currentOpGeneration
        runningOpGeneration = operationGeneration
        defer { if runningOpGeneration == operationGeneration { runningOpGeneration = nil } }

        let outcome: Result<T, Error> = await withTaskCancellationHandler {
            do { return .success(try await withBlockingIO(on: ioQueue, body)) }
            catch { return .failure(error) }
        } onCancel: {
            Task { await self.interruptIfRunning(generation: operationGeneration) }
        }
        if Task.isCancelled { throw CancellationError() }
        return try outcome.get()
    }

    private func interruptIfRunning(generation: UInt64) {
        guard !isClosed, runningOpGeneration == generation else { return }
        sqlite3_interrupt(handle.db)
    }

    // MARK: - Non-public primitives (no transaction-context checks)

    func ensureOpen() throws {
        if isClosed { throw PerunError.connectionClosed }
    }

    private func _runMultiStatement(_ sql: String) async throws -> QueryResult {
        let db = handle
        return try await runCancellable {
            guard !db.closed else { throw PerunError.connectionClosed }
            return try perunRunMultiStatement(sql, db: db.db)
        }
    }

    private func _runSingleStatement(_ sql: String,
                                     _ parameters: [(any SQLiteEncodable)?]) async throws -> QueryResult {
        let db = handle
        return try await runCancellable {
            guard !db.closed else { throw PerunError.connectionClosed }
            return try perunRunSingleStatement(sql, parameters, db: db.db)
        }
    }

    /// Run a control statement (BEGIN/COMMIT/ROLLBACK) uninterruptibly, so a cancel can't leave a
    /// transaction half-open.
    private func _execUninterruptible(_ sql: String) async throws {
        let db = handle
        _ = try await withBlockingIO(on: ioQueue) {
            guard !db.closed else { throw PerunError.connectionClosed }
            return try perunRunSingleStatement(sql, [], db: db.db)
        }
    }

    private func _prepare(_ sql: String) async throws -> PreparedStatement {
        let db = handle
        let prepared: (handle: StatementHandle, columns: [ColumnMetadata], parameterCount: Int) =
            try await withBlockingIO(on: ioQueue) {
                guard !db.closed else { throw PerunError.connectionClosed }
                let stmt = try perunCompileSingle(sql, db: db.db)
                return (StatementHandle(stmt),
                        perunColumnMetadata(stmt),
                        Int(sqlite3_bind_parameter_count(stmt)))
            }
        nextStatementID += 1
        let id = nextStatementID
        statements[id] = prepared.handle
        return PreparedStatement(id: id,
                                 sql: sql,
                                 parameterCount: prepared.parameterCount,
                                 columns: prepared.columns,
                                 connectionID: connectionID)
    }

    private func _execute(_ statement: PreparedStatement,
                          _ parameters: [(any SQLiteEncodable)?]) async throws -> QueryResult {
        try validate(statement)
        guard let statementHandle = statements[statement.id] else {
            throw PerunError.preparedStatementConnectionMismatch
        }
        let db = handle
        return try await runCancellable {
            guard let stmt = statementHandle.stmt else { throw PerunError.connectionClosed }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try perunBindParameters(parameters, to: stmt, db: db.db)
            let columns = perunColumnMetadata(stmt)
            let columnCount = sqlite3_column_count(stmt)
            var values: [[SQLiteValue]] = []
            while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW:
                    values.append(perunReadRow(stmt, columnCount))
                case SQLITE_DONE:
                    let result = QueryResult(columns: columns,
                                             values: values,
                                             rowsAffected: perunRowsAffected(stmt, db.db),
                                             lastInsertRowID: sqlite3_last_insert_rowid(db.db))
                    sqlite3_reset(stmt)
                    return result
                default:
                    let error = perunSQLiteError(db.db)
                    sqlite3_reset(stmt)
                    throw error
                }
            }
        }
    }

    private func _closePrepared(_ statement: PreparedStatement) async throws {
        try validate(statement)
        guard let statementHandle = statements.removeValue(forKey: statement.id) else { return }
        _ = try? await withBlockingIO(on: ioQueue) {
            if let stmt = statementHandle.stmt {
                sqlite3_finalize(stmt)
                statementHandle.stmt = nil
            }
            return ()
        }
    }

    private func validate(_ statement: PreparedStatement) throws {
        guard statement.connectionID == connectionID else {
            throw PerunError.preparedStatementConnectionMismatch
        }
    }
}

// MARK: - Process-local connection ids

private let sqliteConnectionIDQueue = DispatchQueue(label: "perun.sqlite.connection-id")
private nonisolated(unsafe) var sqliteConnectionIDCounter: UInt64 = 0

func nextSQLiteConnectionID() -> UInt64 {
    sqliteConnectionIDQueue.sync {
        sqliteConnectionIDCounter += 1
        return sqliteConnectionIDCounter
    }
}

// MARK: - Free helpers (run on the connection's ioQueue, over raw pointers)

/// Build a `PerunError.sqlite` from a database handle's current error state.
func perunSQLiteError(_ db: OpaquePointer) -> PerunError {
    let extendedCode = sqlite3_extended_errcode(db)
    let message = String(cString: sqlite3_errmsg(db))
    return .sqlite(SQLiteError(extendedCode: extendedCode, message: message))
}

/// Read column names and declared types from a compiled statement.
func perunColumnMetadata(_ stmt: OpaquePointer) -> [ColumnMetadata] {
    let count = sqlite3_column_count(stmt)
    var columns: [ColumnMetadata] = []
    columns.reserveCapacity(Int(count))
    for column in 0 ..< count {
        let name = sqlite3_column_name(stmt, column).map { String(cString: $0) } ?? ""
        let declaredType = sqlite3_column_decltype(stmt, column).map { String(cString: $0) }
        columns.append(ColumnMetadata(name: name, declaredType: declaredType))
    }
    return columns
}

/// Read one row's typed values from a stepped statement.
func perunReadRow(_ stmt: OpaquePointer, _ columnCount: Int32) -> [SQLiteValue] {
    var values: [SQLiteValue] = []
    values.reserveCapacity(Int(columnCount))
    for column in 0 ..< columnCount {
        switch sqlite3_column_type(stmt, column) {
        case SQLITE_INTEGER:
            values.append(.integer(sqlite3_column_int64(stmt, column)))
        case SQLITE_FLOAT:
            values.append(.real(sqlite3_column_double(stmt, column)))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(stmt, column))
            if count > 0, let pointer = sqlite3_column_text(stmt, column) {
                let buffer = UnsafeBufferPointer(start: pointer, count: count)
                values.append(.text(String(decoding: buffer, as: UTF8.self)))
            } else {
                values.append(.text(""))
            }
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(stmt, column))
            if count > 0, let pointer = sqlite3_column_blob(stmt, column) {
                let buffer = UnsafeRawBufferPointer(start: pointer, count: count)
                values.append(.blob(Array(buffer)))
            } else {
                values.append(.blob([]))
            }
        default:
            values.append(.null)      // SQLITE_NULL
        }
    }
    return values
}

/// Rows changed by `stmt` — `0` for a read-only statement (e.g. a `SELECT`), so a `SELECT` result
/// doesn't report an earlier DML's connection-global `sqlite3_changes`. An `INSERT`/`UPDATE`/
/// `DELETE` — including a `RETURNING` form, which is not read-only — reports its real change count.
func perunRowsAffected(_ stmt: OpaquePointer, _ db: OpaquePointer) -> Int {
    sqlite3_stmt_readonly(stmt) != 0 ? 0 : Int(sqlite3_changes(db))
}

/// Bind an array of encodable parameters to a compiled statement, positionally (`?1…?n`).
func perunBindParameters(_ parameters: [(any SQLiteEncodable)?],
                         to stmt: OpaquePointer,
                         db: OpaquePointer) throws {
    let expected = Int(sqlite3_bind_parameter_count(stmt))
    guard parameters.count == expected else {
        throw PerunError.parameterCountMismatch(expected: expected, got: parameters.count)
    }
    for (offset, parameter) in parameters.enumerated() {
        let index = Int32(offset + 1)
        let rc: Int32
        switch parameter?.encode() {
        case nil, .some(.null):
            rc = sqlite3_bind_null(stmt, index)
        case let .some(.integer(value)):
            rc = sqlite3_bind_int64(stmt, index, value)
        case let .some(.real(value)):
            rc = sqlite3_bind_double(stmt, index, value)
        case let .some(.text(string)):
            rc = perunBindText(stmt, index, string)
        case let .some(.blob(bytes)):
            rc = perunBindBlob(stmt, index, bytes)
        }
        guard rc == SQLITE_OK else { throw perunSQLiteError(db) }
    }
}

private func perunBindText(_ stmt: OpaquePointer, _ index: Int32, _ string: String) -> Int32 {
    var string = string
    return string.withUTF8 { buffer in
        guard let base = buffer.baseAddress else {
            return sqlite3_bind_text(stmt, index, "", 0, SQLITE_TRANSIENT)
        }
        // Bind the exact byte length (so embedded NULs survive) and let SQLite copy (TRANSIENT).
        return sqlite3_bind_text(stmt, index,
                                 UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self),
                                 Int32(buffer.count), SQLITE_TRANSIENT)
    }
}

private func perunBindBlob(_ stmt: OpaquePointer, _ index: Int32, _ bytes: [UInt8]) -> Int32 {
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else {
            // An empty array can yield a nil base pointer, and bind_blob(NULL, 0) binds SQL NULL,
            // not an empty BLOB. Bind a valid zero-length pointer instead (mirrors the text path).
            return sqlite3_bind_blob(stmt, index, "", 0, SQLITE_TRANSIENT)
        }
        return sqlite3_bind_blob(stmt, index, base, Int32(raw.count), SQLITE_TRANSIENT)
    }
}

/// Compile and run one or more statements from `sql`, returning the last result set.
func perunRunMultiStatement(_ sql: String, db: OpaquePointer) throws -> QueryResult {
    var lastColumns: [ColumnMetadata] = []
    var lastValues: [[SQLiteValue]] = []
    var lastStatementReadonly = true      // an empty batch changed nothing

    try sql.withCString { start in
        var cursor: UnsafePointer<CChar>? = start
        while let current = cursor, current.pointee != 0 {
            var stmt: OpaquePointer?
            var next: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(db, current, -1, &stmt, &next) == SQLITE_OK else {
                throw perunSQLiteError(db)
            }
            cursor = next
            guard let stmt else { continue }        // whitespace / comment-only tail
            defer { sqlite3_finalize(stmt) }

            let columns = perunColumnMetadata(stmt)
            let columnCount = sqlite3_column_count(stmt)
            var values: [[SQLiteValue]] = []
            step: while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW: values.append(perunReadRow(stmt, columnCount))
                case SQLITE_DONE: break step
                default: throw perunSQLiteError(db)
                }
            }
            lastColumns = columns
            lastValues = values
            lastStatementReadonly = sqlite3_stmt_readonly(stmt) != 0
        }
    }

    return QueryResult(columns: lastColumns,
                       values: lastValues,
                       rowsAffected: lastStatementReadonly ? 0 : Int(sqlite3_changes(db)),
                       lastInsertRowID: sqlite3_last_insert_rowid(db))
}

/// Compile exactly one statement, rejecting a trailing second statement (`SELECT 1; SELECT 2`).
/// Returns the still-open compiled statement — the caller owns finalization. The statement is
/// independent of `sql`'s storage once compiled, so it safely outlives the `withCString` buffer.
func perunCompileSingle(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
    try sql.withCString { cString in
        var stmt: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        guard sqlite3_prepare_v2(db, cString, -1, &stmt, &tail) == SQLITE_OK, let stmt else {
            throw perunSQLiteError(db)
        }
        // Everything after the first statement except whitespace/comments is rejected. Let SQLite
        // parse the tail: a real second statement → multipleStatements; SQL that fails to compile
        // (e.g. `SELECT 1; garbage`) surfaces its own error rather than being silently dropped.
        if let tail {
            var tailStatement: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, tail, -1, &tailStatement, nil)
            guard rc == SQLITE_OK else {
                let error = perunSQLiteError(db)      // capture before finalize resets db error state
                sqlite3_finalize(stmt)
                throw error
            }
            if let tailStatement {
                sqlite3_finalize(tailStatement)
                sqlite3_finalize(stmt)
                throw PerunError.multipleStatements
            }
        }
        return stmt
    }
}

/// Compile and run a single parameterized statement.
func perunRunSingleStatement(_ sql: String,
                             _ parameters: [(any SQLiteEncodable)?],
                             db: OpaquePointer) throws -> QueryResult {
    let stmt = try perunCompileSingle(sql, db: db)
    defer { sqlite3_finalize(stmt) }

    try perunBindParameters(parameters, to: stmt, db: db)
    let columns = perunColumnMetadata(stmt)
    let columnCount = sqlite3_column_count(stmt)
    var values: [[SQLiteValue]] = []
    while true {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            values.append(perunReadRow(stmt, columnCount))
        case SQLITE_DONE:
            return QueryResult(columns: columns,
                               values: values,
                               rowsAffected: perunRowsAffected(stmt, db),
                               lastInsertRowID: sqlite3_last_insert_rowid(db))
        default:
            throw perunSQLiteError(db)
        }
    }
}
