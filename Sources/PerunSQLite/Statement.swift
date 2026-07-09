/// A prepared statement: SQL that has been compiled once (`sqlite3_prepare_v2`) and can be
/// `execute`d many times with different parameters.
///
/// Obtain one from `SQLiteConnection.prepare(_:)` and run it with `SQLiteConnection.execute(_:_:)`.
/// The compiled `sqlite3_stmt` lives inside the connection that created it — this is just the
/// handle — so a statement is scoped to that connection.
public struct PreparedStatement: Sendable {
    /// Registry key for the compiled statement held by the connection.
    let id: UInt64
    /// The SQL text this statement was compiled from.
    public let sql: String
    /// The number of `?` bind parameters the statement expects.
    public let parameterCount: Int
    /// Result columns, learned when the statement was prepared.
    public let columns: [ColumnMetadata]
    /// The connection that created this handle. Statements are scoped to one connection.
    let connectionID: UInt64
}
