# Connection pool

Running work concurrently across many connections.

## SQLiteClient

A ``SQLiteConnection`` serialises its calls and is meant for one logical task at a time. For
concurrency, use a ``SQLiteClient`` pool: it lazily opens up to `maxConnections` connections and
hands each task its own.

```swift
let pool = SQLiteClient(configuration: .file("app.db", journalMode: .wal), maxConnections: 8)

// Fan out — the pool serialises checkout, each task gets its own connection.
async let a = pool.query("SELECT count(*) AS c FROM users").first?.decode("c", as: Int.self)
async let b = pool.query("SELECT count(*) AS c FROM orders").first?.decode("c", as: Int.self)
let (users, orders) = try await (a, b)

await pool.shutdown()
```

Use ``SQLiteClient/withConnection(_:)`` to hold one connection for several statements, or the
convenience ``SQLiteClient/query(_:_:)`` / ``SQLiteClient/withTransaction(kind:_:)`` which check a
connection out, run, and return it automatically.

## Two SQLite-specific notes

- **Use WAL for a file database.** In the default rollback-journal mode readers and writers block
  each other, so a pool buys little. ``JournalMode/wal`` lets many connections read while one writes.
- **`":memory:"` is private per connection.** A pool of plain in-memory connections would each see a
  different, empty database. To share one across the pool, use a shared-cache URI:

  ```swift
  let pool = SQLiteClient(
      configuration: .uri("file::memory:?cache=shared"), maxConnections: 4)
  ```

## Reuse, recycling, and shutdown

The pool reuses a connection after each request unless the error suggests the handle is in a
doubtful state — corruption, an I/O error, an unreadable file — in which case it is discarded and
replaced. Everyday errors (constraint violations, type mismatches) leave the connection usable, so
it is kept (a connection returned mid-transaction is discarded). Optional
`maxConnectionLifetime` / `maxIdleTime` limits recycle connections by age. ``SQLiteClient/shutdown()``
closes every connection and fails anyone still waiting. See <doc:ErrorsAndRecovery> for the
reusability contract.
