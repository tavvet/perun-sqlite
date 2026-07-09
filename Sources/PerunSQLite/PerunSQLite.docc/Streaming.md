# Streaming

Reading a large result one row at a time.

## queryStream

``SQLiteConnection/queryStream(_:_:)`` returns a ``SQLiteRowStream``, an `AsyncSequence` of
``SQLiteRow``. Each `for await` step runs one `sqlite3_step`, so the whole result never lives in
memory at once:

```swift
var total = 0
for try await row in try await connection.queryStream("SELECT amount FROM ledger") {
    total += try row.decode("amount", as: Int.self)
}
```

`sqlite3_step` is itself a cursor, so streaming is the engine's natural mode — a slow consumer simply
steps more slowly.

## Stopping early

Stopping before the end — a `break`, a thrown error, or just dropping the stream — finalises the
underlying statement immediately, so the connection is reusable right away:

```swift
for try await row in try await connection.queryStream("SELECT id FROM big ORDER BY id") {
    if try row.decode("id", as: Int.self) > 1000 { break }
    process(row)
}
```

## One task at a time

Unlike the PostgreSQL driver, a stream does not seize an exclusive wire lock — there is no wire. But
a ``SQLiteConnection`` is meant for one logical task at a time, so keep iterating a stream (and don't
fire other writes on the *same* connection mid-stream) until it ends. For concurrent work, stream on
one connection and run other queries on another — that's what the <doc:ConnectionPool> is for.

Parameters bind the same way as ``SQLiteConnection/query(_:_:)``:

```swift
let stream = try await connection.queryStream("SELECT * FROM events WHERE kind = ?", ["click"])
```
