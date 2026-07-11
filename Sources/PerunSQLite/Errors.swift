/// A typed SQLite result code.
///
/// SQLite reports failures as small integer codes — a *primary* code (e.g. `SQLITE_CONSTRAINT`)
/// and an *extended* code that refines it (e.g. `SQLITE_CONSTRAINT_UNIQUE`). This enum names the
/// codes callers commonly branch on; everything else is `.other(code)`, preserving the raw
/// integer. Like PostgreSQL's SQLSTATE, the result code — not the localized `message` — is the
/// stable thing to switch on.
///
/// The driver reports the condition; mapping it to a domain error — "this unique violation means
/// the email is taken" — is the caller's job.
public enum SQLiteResultCode: Sendable, Equatable, Hashable {
    // Primary result codes (see <https://sqlite.org/rescode.html>).
    case ok                     // SQLITE_OK 0
    case error                  // SQLITE_ERROR 1
    case internalError          // SQLITE_INTERNAL 2
    case permission             // SQLITE_PERM 3
    case abort                  // SQLITE_ABORT 4
    case busy                   // SQLITE_BUSY 5
    case locked                 // SQLITE_LOCKED 6
    case noMemory               // SQLITE_NOMEM 7
    case readonly               // SQLITE_READONLY 8
    case interrupt              // SQLITE_INTERRUPT 9
    case ioError                // SQLITE_IOERR 10
    case corrupt                // SQLITE_CORRUPT 11
    case notFound               // SQLITE_NOTFOUND 12
    case full                   // SQLITE_FULL 13
    case cantOpen               // SQLITE_CANTOPEN 14
    case protocolError          // SQLITE_PROTOCOL 15
    case empty                  // SQLITE_EMPTY 16
    case schema                 // SQLITE_SCHEMA 17
    case tooBig                 // SQLITE_TOOBIG 18
    case constraint             // SQLITE_CONSTRAINT 19
    case mismatch               // SQLITE_MISMATCH 20
    case misuse                 // SQLITE_MISUSE 21
    case noLargeFileSupport     // SQLITE_NOLFS 22
    case authorizationDenied    // SQLITE_AUTH 23
    case format                 // SQLITE_FORMAT 24
    case range                  // SQLITE_RANGE 25
    case notADatabase           // SQLITE_NOTADB 26
    case notice                 // SQLITE_NOTICE 27
    case warning                // SQLITE_WARNING 28
    case row                    // SQLITE_ROW 100
    case done                   // SQLITE_DONE 101

    // Extended codes — constraint subclasses (the ones callers branch on most).
    case constraintCheck        // SQLITE_CONSTRAINT_CHECK 275
    case constraintForeignKey   // SQLITE_CONSTRAINT_FOREIGNKEY 787
    case constraintNotNull      // SQLITE_CONSTRAINT_NOTNULL 1299
    case constraintPrimaryKey   // SQLITE_CONSTRAINT_PRIMARYKEY 1555
    case constraintTrigger      // SQLITE_CONSTRAINT_TRIGGER 1811
    case constraintUnique       // SQLITE_CONSTRAINT_UNIQUE 2067
    case constraintRowID        // SQLITE_CONSTRAINT_ROWID 2579
    case constraintDatatype     // SQLITE_CONSTRAINT_DATATYPE 3091

    // Extended codes — busy subclasses.
    case busyRecovery           // SQLITE_BUSY_RECOVERY 261
    case busySnapshot           // SQLITE_BUSY_SNAPSHOT 517

    /// Any result code the driver does not name, carrying the raw extended-code integer.
    case other(Int32)

    /// Build a typed code from a raw extended result code integer. Values are hard-coded (with
    /// the `SQLITE_*` name in a comment) rather than read from the C macros, since several of the
    /// extended codes are `(primary | (sub << 8))` macro *expressions* the Swift importer does
    /// not expose.
    public init(code: Int32) {
        switch code {
        // Extended codes carry more information than the primary, so match them first.
        case 275:  self = .constraintCheck
        case 787:  self = .constraintForeignKey
        case 1299: self = .constraintNotNull
        case 1555: self = .constraintPrimaryKey
        case 1811: self = .constraintTrigger
        case 2067: self = .constraintUnique
        case 2579: self = .constraintRowID
        case 3091: self = .constraintDatatype
        case 261:  self = .busyRecovery
        case 517:  self = .busySnapshot
        // Primary codes.
        case 0:   self = .ok
        case 1:   self = .error
        case 2:   self = .internalError
        case 3:   self = .permission
        case 4:   self = .abort
        case 5:   self = .busy
        case 6:   self = .locked
        case 7:   self = .noMemory
        case 8:   self = .readonly
        case 9:   self = .interrupt
        case 10:  self = .ioError
        case 11:  self = .corrupt
        case 12:  self = .notFound
        case 13:  self = .full
        case 14:  self = .cantOpen
        case 15:  self = .protocolError
        case 16:  self = .empty
        case 17:  self = .schema
        case 18:  self = .tooBig
        case 19:  self = .constraint
        case 20:  self = .mismatch
        case 21:  self = .misuse
        case 22:  self = .noLargeFileSupport
        case 23:  self = .authorizationDenied
        case 24:  self = .format
        case 25:  self = .range
        case 26:  self = .notADatabase
        case 27:  self = .notice
        case 28:  self = .warning
        case 100: self = .row
        case 101: self = .done
        default:  self = .other(code)
        }
    }

    /// The raw extended result code integer.
    public var code: Int32 {
        switch self {
        case .ok: return 0
        case .error: return 1
        case .internalError: return 2
        case .permission: return 3
        case .abort: return 4
        case .busy: return 5
        case .locked: return 6
        case .noMemory: return 7
        case .readonly: return 8
        case .interrupt: return 9
        case .ioError: return 10
        case .corrupt: return 11
        case .notFound: return 12
        case .full: return 13
        case .cantOpen: return 14
        case .protocolError: return 15
        case .empty: return 16
        case .schema: return 17
        case .tooBig: return 18
        case .constraint: return 19
        case .mismatch: return 20
        case .misuse: return 21
        case .noLargeFileSupport: return 22
        case .authorizationDenied: return 23
        case .format: return 24
        case .range: return 25
        case .notADatabase: return 26
        case .notice: return 27
        case .warning: return 28
        case .row: return 100
        case .done: return 101
        case .constraintCheck: return 275
        case .constraintForeignKey: return 787
        case .constraintNotNull: return 1299
        case .constraintPrimaryKey: return 1555
        case .constraintTrigger: return 1811
        case .constraintUnique: return 2067
        case .constraintRowID: return 2579
        case .constraintDatatype: return 3091
        case .busyRecovery: return 261
        case .busySnapshot: return 517
        case let .other(code): return code
        }
    }

    /// The primary result code (`extended & 0xFF`), e.g. `19` (`SQLITE_CONSTRAINT`) for any of
    /// the `constraint…` conditions.
    public var primaryCode: Int32 { code & 0xFF }

    /// True for any constraint violation (primary code `SQLITE_CONSTRAINT` = 19): unique,
    /// foreign-key, not-null, check, primary-key and the rest.
    public var isConstraintViolation: Bool { primaryCode == 19 }

    /// True when the database was busy or locked (`SQLITE_BUSY` = 5 / `SQLITE_LOCKED` = 6) —
    /// transient contention a caller may retry.
    public var isBusy: Bool { primaryCode == 5 || primaryCode == 6 }
}

/// A structured error reported by the SQLite engine.
///
/// Analogous to perun-pgsql's `PostgresServerError`: it pairs the typed `resultCode` (the stable
/// signal to branch on) with the raw extended integer and the human-readable message.
public struct SQLiteError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The extended result code as a typed condition — branch on this.
    public let resultCode: SQLiteResultCode
    /// The raw extended result code integer (`sqlite3_extended_errcode`). Escape hatch for codes
    /// the driver does not name.
    public let extendedCode: Int32
    /// The human-readable message (`sqlite3_errmsg`). Localized / version-dependent: branch on
    /// `resultCode`, never parse this text.
    public let message: String

    public init(resultCode: SQLiteResultCode, extendedCode: Int32, message: String) {
        self.resultCode = resultCode
        self.extendedCode = extendedCode
        self.message = message
    }

    /// Build from a raw extended result code and message (as read from a database handle).
    public init(extendedCode: Int32, message: String) {
        self.init(resultCode: SQLiteResultCode(code: extendedCode),
                  extendedCode: extendedCode,
                  message: message)
    }

    /// The primary result code integer (`extendedCode & 0xFF`).
    public var primaryCode: Int32 { extendedCode & 0xFF }

    public var description: String {
        "SQLite error \(extendedCode) (\(resultCode)): \(message)"
    }
}

/// Everything the driver itself can throw.
///
/// The trimmed mirror of perun-pgsql's `PerunError`: the wire / auth / TLS / COPY cases are gone
/// (an embedded engine has none of those), and a structured engine failure arrives as
/// `.sqlite(SQLiteError)` — the analogue of `.server(PostgresServerError)`.
public enum PerunError: Error, CustomStringConvertible, Sendable, Equatable {
    /// The database could not be opened — bad path, permissions, or a corrupt file. Thrown by
    /// `connect`, before a usable handle exists.
    case connectionFailed(String)
    /// An operation was attempted on a connection that has been closed.
    case connectionClosed
    /// A structured error from the SQLite engine.
    case sqlite(SQLiteError)
    /// A non-optional value was requested from a column that held SQL NULL.
    case unexpectedNull(column: String)
    /// A row was accessed by a column name that was not present in the result.
    case columnNotFound(String)
    /// A column's value could not be decoded into the requested Swift type.
    case decodingFailed(type: String, storageClass: String, reason: String)
    /// The parameter array's length did not match the statement's `?` placeholder count.
    case parameterCountMismatch(expected: Int, got: Int)
    /// A parameter value cannot be represented in SQLite and was refused rather than bound to
    /// something surprising — e.g. a `Double.nan`, which `sqlite3_bind_double` would silently store
    /// as SQL NULL.
    case invalidParameter(reason: String)
    /// A single-statement API (`query(_:_:)`, `prepare`, `queryStream`) was given SQL containing
    /// more than one statement. Use `query(_:)` (no parameters) to run several statements.
    case multipleStatements
    /// `createFunction` was given an argument count outside SQLite's allowed range: it must be
    /// `nil` (variadic) or `0…127` (values above 127 are undefined behavior in the C API).
    case invalidArgumentCount(Int)
    /// A prepared-statement handle was used on a different connection than the one that created
    /// it. Statements are scoped to their connection.
    case preparedStatementConnectionMismatch
    /// A `Transaction` handle was used after its `withTransaction` scope had already ended (e.g.
    /// it escaped the closure). Its statements would run outside the transaction.
    case invalidTransactionContext
    /// SQLite rolled the transaction back on its own before `withTransaction` could commit — an
    /// `ON CONFLICT ROLLBACK` clause, or a fatal error (`SQLITE_FULL` / `SQLITE_IOERR` / …). No
    /// changes made inside the transaction were committed. Thrown instead of silently letting the
    /// statements that ran after the rollback commit one at a time.
    case transactionRolledBack
    /// An operation was requested on a pool that has been shut down.
    case clientShutdown
    /// An operation wrapped in `withTimeout` did not finish before its deadline. The underlying
    /// statement was interrupted (`sqlite3_interrupt`), so the connection stays usable.
    case timedOut

    public var description: String {
        switch self {
        case let .connectionFailed(detail):
            return "could not open database: \(detail)"
        case .connectionClosed:
            return "the connection has been closed"
        case let .sqlite(error):
            return error.description
        case let .unexpectedNull(column):
            return "unexpected NULL decoding column \"\(column)\""
        case let .columnNotFound(column):
            return "column \"\(column)\" was not found in this row"
        case let .decodingFailed(type, storageClass, reason):
            return "could not decode \(type) from \(storageClass): \(reason)"
        case let .parameterCountMismatch(expected, got):
            return "parameter count mismatch: statement expects \(expected), got \(got)"
        case let .invalidParameter(reason):
            return "invalid parameter: \(reason)"
        case .multipleStatements:
            return "SQL contains more than one statement; use query(_:) to run several"
        case let .invalidArgumentCount(count):
            return "invalid function argument count \(count): must be nil (variadic) or 0…127"
        case .preparedStatementConnectionMismatch:
            return "prepared statement belongs to a different connection"
        case .invalidTransactionContext:
            return "transaction handle used outside its withTransaction scope"
        case .transactionRolledBack:
            return "the transaction was rolled back by SQLite before it could commit; no changes were committed"
        case .clientShutdown:
            return "the connection pool has been shut down"
        case .timedOut:
            return "operation timed out"
        }
    }
}

extension PerunError {
    /// The structured engine error, when this is a `.sqlite` error — so callers can reach
    /// `resultCode` without unwrapping the case by hand (mirrors `PerunError.serverError`).
    public var sqliteError: SQLiteError? {
        if case let .sqlite(error) = self { return error }
        return nil
    }

    /// Whether a pooled connection that hit this error should be discarded rather than reused.
    ///
    /// The SQLite analogue of perun-pgsql's `mayHaveDesynchronizedWire`. There is no wire to
    /// desync, but a handful of failures leave the *handle* in a doubtful state — corruption,
    /// I/O errors, an unreadable file, OOM. The everyday errors (constraint violations, type
    /// mismatches, misuse, decode/local failures) leave the connection perfectly usable, so the
    /// pool keeps it. The outer switch is exhaustive, so a new `PerunError` case forces a
    /// decision here.
    var shouldDiscardConnection: Bool {
        switch self {
        case .connectionClosed, .connectionFailed:
            return true
        case let .sqlite(error):
            // Classify on the PRIMARY code, not the named enum cases: extended result codes are
            // enabled (`sqlite3_extended_result_codes`), so a real I/O or corruption failure
            // arrives as an *extended* code (e.g. SQLITE_IOERR_READ = 266, SQLITE_CORRUPT_VTAB =
            // 267) that would fall through named cases like `.ioError`/`.corrupt` into `.other`.
            switch error.primaryCode {
            case 7, 10, 11, 14, 26:      // NOMEM, IOERR, CORRUPT, CANTOPEN, NOTADB
                return true
            default:
                return false
            }
        case .unexpectedNull, .columnNotFound, .decodingFailed, .parameterCountMismatch,
             .invalidParameter, .multipleStatements, .invalidArgumentCount,
             .preparedStatementConnectionMismatch,
             .invalidTransactionContext, .transactionRolledBack, .clientShutdown, .timedOut:
            // A rolled-back transaction leaves the connection perfectly usable (autocommit is back
            // on), so the pool keeps it.
            return false
        }
    }
}
