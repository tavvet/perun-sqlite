# Connecting

Opening a database, and the configuration and pragmas the driver applies.

## Opening a database

``SQLiteConnection/connect(_:)`` takes a ``SQLiteConfiguration``. Three factories cover the common
cases:

```swift
let onDisk   = try await SQLiteConnection.connect(.file("app.db"))
let inMemory = try await SQLiteConnection.connect(.memory())
let shared   = try await SQLiteConnection.connect(.uri("file::memory:?cache=shared"))
```

- ``SQLiteConfiguration/file(_:readonly:create:journalMode:)`` — a file at a path.
- ``SQLiteConfiguration/memory()`` — a private in-memory database that vanishes on close.
- ``SQLiteConfiguration/uri(_:readonly:create:journalMode:)`` — a URI filename (`SQLITE_OPEN_URI`),
  for `mode=`/`cache=` options — e.g. a shared-cache in-memory database a pool can share.

## Configuration

``SQLiteConfiguration`` also lets you set open flags and the pragmas the driver applies on open:

```swift
var config = SQLiteConfiguration(path: "app.db")
config.readonly = false          // SQLITE_OPEN_READONLY when true (then `create` is ignored)
config.create = true             // create the file if missing (SQLITE_OPEN_CREATE)
config.journalMode = .wal        // PRAGMA journal_mode — .wal enables concurrent readers
config.busyTimeout = .seconds(5) // sqlite3_busy_timeout — wait this long for a lock before failing
config.enableForeignKeys = true  // PRAGMA foreign_keys = ON (SQLite defaults this off; we default it on)
```

- **`journalMode`** — leave `nil` for SQLite's default, or set ``JournalMode/wal`` for a file
  database you'll read concurrently (see <doc:ConnectionPool>).
- **`busyTimeout`** — how long a blocked operation waits for a lock before failing with
  `SQLITE_BUSY`. `nil` fails immediately.
- **`enableForeignKeys`** — on by default here (SQLite ships it off).
- **`observeDataChanges`** — opt into row-change notifications (see <doc:DataChanges>).

## Closing

Call ``SQLiteConnection/close()`` when you're done. It finalises any prepared statements and open
streams, then closes the handle. As a safety net a dropped connection is also cleaned up on
deallocation, but prefer an explicit `close()` (or a pool, which manages it for you).

```swift
try await connection.close()
```
