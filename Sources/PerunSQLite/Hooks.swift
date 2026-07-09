import CSQLite

/// A row-level change reported by SQLite's update hook (`sqlite3_update_hook`).
///
/// This is the closest embedded analogue of PostgreSQL's LISTEN/NOTIFY: it fires for every
/// insert / update / delete on the *owning connection* (not across connections), so it observes
/// this connection's own writes. Delivered on `SQLiteConnection.dataChanges` when the
/// configuration sets `observeDataChanges`.
public struct SQLiteChange: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        case insert
        case update
        case delete
    }

    /// Which kind of change occurred.
    public let operation: Operation
    /// The database name (usually `"main"`).
    public let database: String
    /// The table that changed.
    public let table: String
    /// The rowid of the affected row (the new rowid for insert/update, the old one for delete).
    public let rowID: Int64
}

/// Retains the change stream's continuation so the C update hook can reach it through a raw
/// pointer. `@unchecked Sendable` because `AsyncStream.Continuation.yield` is itself thread-safe.
final class ChangeHookBox: @unchecked Sendable {
    let continuation: AsyncStream<SQLiteChange>.Continuation
    init(_ continuation: AsyncStream<SQLiteChange>.Continuation) {
        self.continuation = continuation
    }
}

extension SQLiteConnection {
    /// Install the update hook so row changes flow into `dataChanges`. Called on open when
    /// `observeDataChanges` is set. The hook is removed in `close()`.
    func installChangeHooks() async {
        let box = ChangeHookBox(changeContinuation)
        changeHookBox = box                    // strong ref keeps the box alive for the hook
        let db = handle
        _ = try? await withBlockingIO(on: ioQueue) {
            // The box is reached via an unretained opaque pointer; it outlives the hook because
            // the connection holds `changeHookBox` until the hook is removed on close.
            let context = Unmanaged.passUnretained(box).toOpaque()
            sqlite3_update_hook(db.db, { rawContext, operation, databaseName, tableName, rowID in
                guard let rawContext else { return }
                let box = Unmanaged<ChangeHookBox>.fromOpaque(rawContext).takeUnretainedValue()
                let mappedOperation: SQLiteChange.Operation
                switch operation {
                case SQLITE_INSERT: mappedOperation = .insert
                case SQLITE_UPDATE: mappedOperation = .update
                case SQLITE_DELETE: mappedOperation = .delete
                default: return
                }
                box.continuation.yield(SQLiteChange(
                    operation: mappedOperation,
                    database: databaseName.map { String(cString: $0) } ?? "",
                    table: tableName.map { String(cString: $0) } ?? "",
                    rowID: rowID))
            }, context)
            return ()
        }
    }
}
