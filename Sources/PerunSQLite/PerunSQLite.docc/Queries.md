# Running queries

Parameters, single vs. multiple statements, and prepared statements.

## Parameterised queries

``SQLiteConnection/query(_:_:)`` runs one statement with bound parameters. Values bind positionally
to `?` placeholders; a `nil` element is SQL `NULL`:

```swift
let result = try await connection.query(
    "SELECT id, name FROM users WHERE score > ? AND active = ?", [4.5, true])

for row in result.rows {
    let id = try row.decode("id", as: Int.self)
    let name = try row.decode("name", as: String.self)
    print(id, name)
}
```

A ``QueryResult`` carries the ``QueryResult/rows``, the ``QueryResult/columns``, and — for a write —
``QueryResult/rowsAffected`` and ``QueryResult/lastInsertRowID`` (a read-only statement reports
`0` affected). ``QueryResult/first`` is a shortcut for the common fetch-one-row case.

## One statement or several

The two `query` overloads differ deliberately:

- ``SQLiteConnection/query(_:)`` (no parameters) runs **several** statements separated by `;`, like
  `sqlite3_exec`, and returns the last result set. Each runs in autocommit — wrap them in a
  <doc:Transactions> for atomicity.
- ``SQLiteConnection/query(_:_:)`` (with parameters) runs exactly **one** statement. Text after the
  first `;` is a mistake, so it throws ``PerunError/multipleStatements`` rather than silently
  dropping it. The same holds for `prepare` and `queryStream`.

## Prepared statements

Compile a statement once with ``SQLiteConnection/prepare(_:)`` and run it many times with
``SQLiteConnection/execute(_:_:)`` — ideal for a bulk insert:

```swift
let insert = try await connection.prepare("INSERT INTO points (x, y) VALUES (?, ?)")
for (x, y) in coordinates {
    try await connection.execute(insert, [x, y])
}
try await connection.closePrepared(insert)
```

A ``PreparedStatement`` is scoped to the connection that created it; using it on another throws
``PerunError/preparedStatementConnectionMismatch``. Call ``SQLiteConnection/closePrepared(_:)`` when
done — especially before returning a pooled connection, so the compiled statement doesn't ride along
to the next borrower. Inside a transaction, prepare and execute through the
``SQLiteConnection/Transaction`` handle.

## Reading values

Decode a cell by column name or index — see <doc:DecodingAndEncoding> for the full type system:

```swift
let row = result.rows[0]
let id    = try row.decode("id", as: Int.self)          // throws on NULL / missing / type mismatch
let note  = try row.decodeIfPresent("note", as: String.self)   // nil on SQL NULL
let first = try row[0].decode(Int.self)                 // by index
```
