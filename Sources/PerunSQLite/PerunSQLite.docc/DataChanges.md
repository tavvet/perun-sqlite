# Data-change hooks

Observing row inserts, updates, and deletes as they happen.

## Observing changes

SQLite's update hook is the closest embedded analogue of PostgreSQL's `LISTEN`/`NOTIFY`: it fires
for every insert, update, and delete on the connection. Opt in with
``SQLiteConfiguration/observeDataChanges``, then consume ``SQLiteConnection/dataChanges``, an
`AsyncStream` of ``SQLiteChange``:

```swift
let connection = try await SQLiteConnection.connect(
    SQLiteConfiguration(path: "app.db", observeDataChanges: true))

let observer = Task {
    for await change in connection.dataChanges {
        print("\(change.operation) on \(change.table) rowid=\(change.rowID)")
    }
}
```

Each ``SQLiteChange`` carries the ``SQLiteChange/operation`` (``SQLiteChange/Operation/insert`` /
``SQLiteChange/Operation/update`` / ``SQLiteChange/Operation/delete``), the ``SQLiteChange/table``,
the ``SQLiteChange/database`` (usually `"main"`), and the affected ``SQLiteChange/rowID``.

## What it is, and isn't

- It observes **this connection's own writes**, not changes made by other connections — it is a local
  hook, not a cross-connection channel. (A pooled writer's changes are seen by whichever pooled
  connection made them.)
- It reports the fact of a change, not the old or new row values — read those with a query if needed.
- Events are buffered (newest-wins beyond a bound), so writes may happen before the consumer drains
  them; order is preserved.

It's off by default because the hook adds a callback per changed row. Leave `observeDataChanges` unset
and ``SQLiteConnection/dataChanges`` simply stays empty.
