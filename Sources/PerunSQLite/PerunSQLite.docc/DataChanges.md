# Data-change hooks

Observing row inserts, updates, and deletes as they happen.

## Observing changes

SQLite's update hook is the closest embedded analogue of PostgreSQL's `LISTEN`/`NOTIFY`: it reports
row-level work performed on the connection. Opt in with
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
- It is **not a commit stream**: an event can be delivered for a row change that a later `ROLLBACK`
  undoes. Do not use it as confirmation that a transaction committed.
- It covers SQLite **rowid tables** only. `WITHOUT ROWID` tables and internal system tables do not
  trigger it; SQLite also omits some deletes caused by `ON CONFLICT REPLACE` and by its truncate
  optimization. If every durable change matters, record an application-level event in the same
  transaction instead.
- It reports the fact of a change, not the old or new row values — read those with a query if needed.
- Events are buffered (newest-wins beyond a bound), so writes may happen before the consumer drains
  them; order is preserved.
- It has **one consumer**: ``SQLiteConnection/dataChanges`` is a single `AsyncStream`, so each event
  goes to exactly one `for await` loop. Don't iterate it from two tasks expecting both to see every
  change — they would split the events between them. Fan out in your own code if you need that.

It's off by default because the hook adds a callback per changed row. Leave `observeDataChanges` unset
and ``SQLiteConnection/dataChanges`` simply stays empty.
