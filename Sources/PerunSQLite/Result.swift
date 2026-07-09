/// Metadata describing one column of a result set.
public struct ColumnMetadata: Sendable, Equatable {
    public let name: String
    /// The column's declared type from the schema (`sqlite3_column_decltype`), e.g. `"INTEGER"`,
    /// `"TEXT"`, `"VARCHAR(50)"`. `nil` for expression columns (`SELECT a + b`): SQLite reports a
    /// declared type only for a column that maps directly to a table column. SQLite is
    /// dynamically typed, so this is the *declared* affinity, not the runtime storage class of
    /// any given cell — see `SQLiteValue.storageClass` for that.
    public let declaredType: String?

    public init(name: String, declaredType: String? = nil) {
        self.name = name
        self.declaredType = declaredType
    }
}

/// A single cell: one column's typed value in one row, plus the column's metadata.
///
/// Decode it with `decode(_:)` / `decodeIfPresent(_:)`. The `string()`/`int()`/… helpers are
/// convenience shortcuts over the same decoders.
public struct SQLiteCell: Sendable, Equatable {
    /// The typed value held by this cell.
    public let value: SQLiteValue
    public let column: ColumnMetadata

    public init(value: SQLiteValue, column: ColumnMetadata) {
        self.value = value
        self.column = column
    }

    public var isNull: Bool { value.isNull }

    // Convenience accessors. They return nil on NULL or on a decoding failure; use `decode(_:)`
    // when you want the error.
    public func string() -> String? { value.isNull ? nil : try? decode(String.self) }
    public func int() -> Int? { value.isNull ? nil : try? decode(Int.self) }
    public func double() -> Double? { value.isNull ? nil : try? decode(Double.self) }
    public func bool() -> Bool? { value.isNull ? nil : try? decode(Bool.self) }
}

/// One row of a result set.
public struct SQLiteRow: Sendable, Equatable {
    /// Column values in column order.
    public let values: [SQLiteValue]
    public let columns: [ColumnMetadata]
    private let columnIndexByName: [String: Int]

    init(values: [SQLiteValue], columns: [ColumnMetadata]) {
        self.init(values: values,
                  columns: columns,
                  columnIndexByName: Self.makeColumnIndexByName(columns))
    }

    init(values: [SQLiteValue], columns: [ColumnMetadata], columnIndexByName: [String: Int]) {
        self.values = values
        self.columns = columns
        self.columnIndexByName = columnIndexByName
    }

    /// Access a cell by column index.
    public subscript(index: Int) -> SQLiteCell {
        SQLiteCell(value: values[index], column: columns[index])
    }

    /// Access a cell by column name (first match). Returns nil if no such column.
    public subscript(name: String) -> SQLiteCell? {
        guard let index = columnIndexByName[name] else {
            return nil
        }
        return self[index]
    }

    /// Access a cell by column name, throwing if the column is not present.
    public func cell(_ name: String) throws -> SQLiteCell {
        guard let cell = self[name] else {
            throw PerunError.columnNotFound(name)
        }
        return cell
    }

    /// Decode a non-NULL column by name, throwing on missing columns, NULLs, or type mismatches.
    public func decode<T: SQLiteDecodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try cell(name).decode(type)
    }

    /// Decode a nullable column by name. Missing columns still throw; SQL NULL returns nil.
    public func decodeIfPresent<T: SQLiteDecodable>(_ name: String,
                                                    as type: T.Type = T.self) throws -> T? {
        try cell(name).decodeIfPresent(type)
    }

    static func makeColumnIndexByName(_ columns: [ColumnMetadata]) -> [String: Int] {
        var indexByName: [String: Int] = [:]
        indexByName.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() where indexByName[column.name] == nil {
            indexByName[column.name] = index
        }
        return indexByName
    }
}

/// The outcome of running one SQL statement.
public struct QueryResult: Sendable, Equatable {
    public let columns: [ColumnMetadata]
    public let rows: [SQLiteRow]
    /// Rows changed by the statement (`sqlite3_changes`) — for `INSERT`/`UPDATE`/`DELETE`. `0`
    /// for a `SELECT`. Replaces perun-pgsql's textual `commandTag`.
    public let rowsAffected: Int
    /// The rowid of the most recent successful `INSERT` on the connection
    /// (`sqlite3_last_insert_rowid`) as of when the statement finished. `0` if none has occurred.
    public let lastInsertRowID: Int64

    init(columns: [ColumnMetadata],
         values: [[SQLiteValue]],
         rowsAffected: Int,
         lastInsertRowID: Int64) {
        let columnIndexByName = SQLiteRow.makeColumnIndexByName(columns)
        self.init(columns: columns,
                  rows: values.map {
                      SQLiteRow(values: $0, columns: columns, columnIndexByName: columnIndexByName)
                  },
                  rowsAffected: rowsAffected,
                  lastInsertRowID: lastInsertRowID)
    }

    init(columns: [ColumnMetadata],
         rows: [SQLiteRow],
         rowsAffected: Int,
         lastInsertRowID: Int64) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.lastInsertRowID = lastInsertRowID
    }

    public var rowCount: Int { rows.count }

    /// The first row, or `nil` if the result is empty — a shortcut for the common
    /// fetch-one-row / fetch-a-count pattern (`try result.first?.decode("n", as: Int.self)`).
    public var first: SQLiteRow? { rows.first }
}
