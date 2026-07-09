# Online backup

Copying a whole database between connections.

## backup(to:)

``SQLiteConnection/backup(to:sourceName:destinationName:)`` streams every page of one database into
another with SQLite's online backup API. It's the embedded analogue of a bulk dump/load — useful for
snapshotting an in-memory database to disk, or loading a file into memory:

```swift
// Build in memory, then snapshot to a file.
let memory = try await SQLiteConnection.connect(.memory())
try await memory.query("CREATE TABLE t (v INTEGER)")
try await memory.query("INSERT INTO t VALUES (1), (2), (3)")

let file = try await SQLiteConnection.connect(.file("snapshot.db"))
try await memory.backup(to: file)
try await file.close()
```

Loading works the other way round — `try await onDisk.backup(to: inMemory)`.

## The contract

The copy runs on the source connection's queue and drives the backup against the destination's
handle directly, so:

- The **destination must be exclusively owned** for the duration — don't run other operations on it
  while the backup is in flight. Typically it's a connection opened just to receive the copy.
- The source is busy with the copy for the duration too, though *other* connections to the same file
  may keep reading it.

`sourceName` / `destinationName` name the schema (attached database), usually `"main"`.
