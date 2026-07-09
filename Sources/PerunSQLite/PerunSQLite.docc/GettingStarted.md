# Getting started

Add the driver, open a database, and run your first query.

## Requirements

- Swift 6 or newer, on macOS 13+ or Linux.
- **`libsqlite3`**, located with `pkg-config`.

### macOS

SQLite ships with the SDK, so there is nothing to install — the package builds out of the box. (If
you have Homebrew's `sqlite` on your `pkg-config` path, the driver links that instead; either works.)

### Linux (Debian / Ubuntu)

```sh
sudo apt install libsqlite3-dev pkg-config
```

## Adding the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/tavvet/perun-sqlite", from: "0.1.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [.product(name: "PerunSQLite", package: "perun-sqlite")]
    ),
]
```

## Your first query

Open a file-backed database (or ``SQLiteConfiguration/memory()`` for a private in-memory one), run a
statement, and close it:

```swift
import PerunSQLite

let connection = try await SQLiteConnection.connect(.file("app.db"))

try await connection.query("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)")
try await connection.query("INSERT INTO users (email) VALUES (?)", ["ada@example.com"])

let email = try await connection.query("SELECT email FROM users WHERE id = ?", [1])
    .first?.decode("email", as: String.self)
print(email ?? "—")

try await connection.close()
```

Parameters use `?` placeholders and are bound separately from the SQL text, so the query API is
injection-safe by construction. A `nil` element in the parameter array is SQL `NULL`.

## Using a pool

For concurrency, prefer a ``SQLiteClient`` pool over a single connection — it opens connections on
demand and hands each task its own. Open the database in WAL mode so pooled readers don't block the
writer:

```swift
let pool = SQLiteClient(configuration: .file("app.db", journalMode: .wal), maxConnections: 8)

let count = try await pool.query("SELECT count(*) AS c FROM users")
    .first?.decode("c", as: Int.self)

await pool.shutdown()
```

## Next steps

- <doc:Connecting> — configuration, journal modes, and pragmas.
- <doc:DecodingAndEncoding> — the type system and custom codecs.
- <doc:ErrorsAndRecovery> — the error model, reusability, cancellation, and timeouts.

The `Examples/` directory holds small runnable programs; run one with `swift run Examples basic-query`.
Every scenario uses an in-memory or temporary-file database, so none needs any setup.
