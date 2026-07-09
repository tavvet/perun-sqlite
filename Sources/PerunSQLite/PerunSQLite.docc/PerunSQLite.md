# ``PerunSQLite``

A thin, typed SQLite driver for Swift, wrapping `libsqlite3` on `async`/`await`.

## Overview

PerunSQLite is an embedded database driver — it links `libsqlite3` and calls into it directly, so
there is no server, no network, and no dependency beyond the SQLite library itself. It gives you a
connection and a pool, parameterised queries, transactions, row streaming, an online backup, data
change hooks, custom SQL functions, and typed decoding of SQLite's storage classes.

It mirrors the public shape of its PostgreSQL sibling, `perun-pgsql`, wherever an embedded engine
makes it meaningful, so code and higher layers move between the two with little friction. Like that
driver it is a **data-access layer, not a query builder**: it runs SQL and moves typed values;
building SQL, mapping rows to model types, and migrations belong above it.

```swift
let pool = SQLiteClient(configuration: .file("app.db", journalMode: .wal), maxConnections: 8)

let rows = try await pool.query("SELECT id, email FROM users WHERE id = ?", [id]).rows
let email = try rows[0].decode("email", as: String.self)

await pool.shutdown()
```

Parameters are bound out of band (`?`), never spliced into the SQL text, so the query API is
injection-safe by construction.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Connecting>
- ``SQLiteConnection``
- ``SQLiteClient``
- ``SQLiteConfiguration``

### Working with data

- <doc:Queries>
- <doc:Transactions>
- <doc:ConnectionPool>
- <doc:Streaming>
- ``PreparedStatement``

### SQLite features

- <doc:Backup>
- <doc:DataChanges>
- <doc:Functions>

### Handling failure

- <doc:ErrorsAndRecovery>
- ``PerunError``
- ``SQLiteError``
- ``SQLiteResultCode``
- ``withTimeout(_:_:)``

### Working with results

- ``QueryResult``
- ``SQLiteRow``
- ``SQLiteCell``
- ``ColumnMetadata``

### Decoding and encoding

- <doc:DecodingAndEncoding>
- ``SQLiteValue``
- ``SQLiteDecodable``
- ``SQLiteEncodable``
- ``SQLiteJSON``

### Under the hood

- <doc:Architecture>
