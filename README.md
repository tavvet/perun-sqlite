# perun-sqlite

[![CI](https://github.com/tavvet/perun-sqlite/actions/workflows/ci.yml/badge.svg)](https://github.com/tavvet/perun-sqlite/actions/workflows/ci.yml)
[![Documentation](https://github.com/tavvet/perun-sqlite/actions/workflows/docs.yml/badge.svg)](https://tavvet.github.io/perun-sqlite/documentation/perunsqlite/)

**The SQLite driver for the [Perun](#part-of-the-perun-framework) framework** — a thin, typed,
async/await wrapper over `libsqlite3`. It mirrors the public surface of
[perun-pgsql](../perun-pgsql) (its PostgreSQL sibling) wherever an embedded engine makes it
meaningful: the same connection / pool / result / decode / encode / streaming / transaction /
prepared-statement / timeout shapes, over SQLite instead of a network protocol.

```swift
import PerunSQLite

let connection = try await SQLiteConnection.connect(.file("app.db", journalMode: .wal))

// Parameterized query — values never touch the SQL string (injection-safe).
let result = try await connection.query(
    "SELECT id, name, created FROM users WHERE id = ?", [42])

for row in result.rows {
    let id   = try row.decode("id", as: Int.self)
    let name = try row.decode("name", as: String.self)
    let when = try row.decode("created", as: Date.self)
    print(id, name, when)
}

try await connection.close()
```

## Part of the Perun framework

- **Perun** — the framework (the umbrella project).
- **perun-pgsql** — the PostgreSQL driver — raw wire protocol, auth, types, TLS, pool.
- **perun-sqlite** — *this repository*: the SQLite driver — a typed wrapper over `libsqlite3`.
- **Perun ORM** — built on top of these drivers: models, relationships, query building, migrations.

This package is a lowest layer. It owns the calls into SQLite and gives the ORM typed rows,
prepared statements, a connection pool and transactions. Everything higher-level — a query builder,
row-to-model mapping, migrations — lives in the ORM and leans on the primitives here.

> **Module name:** the Swift module is **`PerunSQLite`** (`import PerunSQLite`), matching the
> repository. It shares the public shape of `PerunPGSQL` so code and the ORM can move between them.

## PostgreSQL and SQLite are not the same shape

perun-pgsql is a client/server driver: sockets, a wire protocol, authentication, TLS, text/binary
formats, type OIDs, a background reader that pipelines requests. SQLite is *embedded* — you link a
library and call C functions — so that entire transport bottom half has no analogue and is gone.
What remains is mirrored deliberately:

| perun-pgsql | perun-sqlite | note |
|---|---|---|
| `PostgresConnection` | `SQLiteConnection` | an `actor` over one handle; blocking calls off the cooperative pool |
| `PostgresClient` | `SQLiteClient` | lazy, bounded connection pool |
| `PostgresRow` / `PostgresCell` | `SQLiteRow` / `SQLiteCell` | by-index / by-name access, typed decode |
| `PostgresDecodable` / `PostgresEncodable` | `SQLiteDecodable` / `SQLiteEncodable` | typed values, no text/binary split |
| raw bytes + OID + format | `SQLiteValue` | SQLite hands back typed values, so cells carry them typed |
| `PostgresServerError` / `SQLState` | `SQLiteError` / `SQLiteResultCode` | typed, switchable error codes |
| `queryStream` (portal chunks) | `queryStream` (`sqlite3_step`) | lazy row-at-a-time cursor |
| `withTransaction` | `withTransaction` | BEGIN / COMMIT / ROLLBACK |
| `withTimeout` (CancelRequest) | `withTimeout` (`sqlite3_interrupt`) | cancellation-aware deadlines |
| LISTEN/NOTIFY | data-change hooks | `sqlite3_update_hook` → `AsyncStream` |
| COPY | online backup | `sqlite3_backup_*` |
| — | custom SQL functions | `sqlite3_create_function` (no PG analogue) |

Dropped as meaningless for an embedded engine: the wire protocol, SCRAM/MD5 auth, TLS, the crypto
primitives, sockets, request pipelining, arrays, and the interval/time/inet types.

## What's implemented

| Layer | Details |
|-------|---------|
| **Engine** | Thin wrapper over `libsqlite3`; every C call runs on a per-connection serial queue, bridged to async/await so a blocking `sqlite3_step` never stalls the cooperative pool |
| **Values** | `SQLiteValue` — the five storage classes (NULL / INTEGER / REAL / TEXT / BLOB) carried typed to decoding |
| **Queries** | Multi-statement `query`, parameterized `query` with positional `?` binding, prepared statements, row **streaming**, all typed |
| **Types** | `Int*`, `Float`/`Double`, `Bool`, `String`, `[UInt8]`/`Data` (BLOB), `UUID`, `Date` (ISO-8601 / Unix / Julian), `Decimal`, `SQLiteJSON`, and your own via `SQLiteDecodable`/`SQLiteEncodable` |
| **Transactions** | `withTransaction { }` (DEFERRED / IMMEDIATE / EXCLUSIVE); BEGIN/COMMIT/ROLLBACK run uninterruptibly so a timed-out transaction still rolls back |
| **Pool** | `SQLiteClient` — lazy, bounded, `withConnection {}`, validate/replace, age-based recycling, graceful shutdown |
| **Errors** | `SQLiteResultCode` — typed primary + extended codes (`.constraintUnique`, `.busySnapshot`, …) with class helpers; `SQLiteError` preserves the raw code and message |
| **Deadlines** | `withTimeout` interrupts a running statement (`sqlite3_interrupt`) and leaves the connection reusable |
| **Config** | file / `:memory:` / URI, read-only, `PRAGMA journal_mode` (WAL), `busy_timeout`, `foreign_keys` |
| **Extras** | Data-change hooks (`AsyncStream<SQLiteChange>`), online **backup** between connections, and custom scalar **SQL functions** written in Swift |

## Requirements

- Swift 6.0+
- `libsqlite3`, located via `pkg-config`. On macOS it ships with the SDK, so nothing to install; on
  Debian/Ubuntu: `apt install libsqlite3-dev pkg-config`. (If you have Homebrew's `sqlite` on the
  pkg-config path, SwiftPM will link that; the driver works with either.)

## Documentation

The full guides are DocC articles. Build them (into a `.doccarchive` you can open in Xcode) with:

```bash
./Scripts/build-docs.sh
```

- **Getting started** — install, open a database, run your first query.
- **Connecting** — configuration, journal modes, and pragmas.
- **Running queries**, **Transactions**, **Connection pool**, **Streaming** — the data-access core.
- **Online backup**, **Data-change hooks**, **Custom SQL functions** — the SQLite-native extras.
- **Decoding and encoding** — the type system and custom codecs.
- **Errors and recovery** — the error model, the reusability contract, cancellation, timeouts.
- **Architecture** — how the driver is put together.

Every push to `main` publishes the site to GitHub Pages via
[`.github/workflows/docs.yml`](.github/workflows/docs.yml) (one-time setup: repository Settings →
Pages → Source = "GitHub Actions").

## Testing

```bash
swift test                       # the whole suite — runs entirely against in-memory databases
swift run perun-demo             # an end-to-end tour (schema, params, transaction, stream, pool,
                                 # function, change hook, backup) — no server needed
swift run Examples basic-query   # a single runnable example
```

Unlike perun-pgsql, **no external server is required for any test** — SQLite is embedded, so the
suite opens `:memory:` (and temporary files for the pool/backup) and needs nothing else. Runnable,
compile-checked examples live in [`Examples/`](Examples): `swift run Examples <scenario>` (e.g.
`basic-query`, `transactions`, `streaming`, `pool`, `error-handling`, `custom-type`, `functions`,
`backup`, `hooks`).

## Architecture

```
        Your code
            │  async/await
   ┌────────▼─────────┐        ┌──────────────────┐
   │ SQLiteClient     │  pool  │ SQLiteConnection  │  actor over one sqlite3*
   │ (actor)          ├───────▶│ (actor)           │
   └──────────────────┘        └───────┬──────────┘
                                        │ typed values
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
              SQLiteValue          Type codecs         SQLiteError
             storage classes    decode / encode      result codes
                                        │
                                        ▼
                          withBlockingIO (serial queue)
                                        ▼
                             libsqlite3 (blocking C)
```

Only the type layer imports Foundation (for `UUID` / `Date` / `Data` / `Decimal`); the rest is Swift
plus `libsqlite3`.

## A note on concurrency

A `SQLiteConnection` serializes its calls, but is intended for one logical task at a time: don't
fire other queries on the *same* connection while a `withTransaction` or `queryStream` is in
progress on it. For real concurrency use `SQLiteClient` (the pool), which hands each task its own
connection — and open the database in WAL mode (`journalMode: .wal`) so pooled readers don't block
the writer. A plain `":memory:"` database is private per connection; to pool an in-memory database,
share it with a URI: `SQLiteConfiguration(path: "file::memory:?cache=shared", enableURIFilenames: true)`.

## Project layout

```
Sources/
  CSQLite/            C-interop shim for libsqlite3 (located via pkg-config)
  PerunSQLite/
    SQLiteConnection.swift   the connection actor + query/transaction primitives
    SQLiteClient.swift       the pool
    Value.swift              SQLiteValue (storage classes)
    Result.swift             ColumnMetadata / SQLiteCell / SQLiteRow / QueryResult
    Encoding.swift           SQLiteEncodable + scalar conformances
    Errors.swift             PerunError / SQLiteError / SQLiteResultCode
    Statement.swift          PreparedStatement handle
    RowStream.swift          SQLiteRowStream (AsyncSequence)
    Timeout.swift            withTimeout
    Concurrency.swift        withBlockingIO + @unchecked Sendable handle boxes
    Hooks.swift              data-change hooks
    Backup.swift             online backup API
    Functions.swift          custom SQL functions
    Types/                   SQLiteDecodable + scalar/Foundation/JSON codecs
  perun-demo/         a small end-to-end program
Examples/             runnable, compile-checked examples (swift run Examples <scenario>)
Tests/PerunTests/     value/type/result/error unit tests + connection/pool/extras integration
```

## Status

`v0.1.3` — pre-1.0, so the API may still change. The driver is complete and verified: `swift test`
(69 tests) and `swift run perun-demo` pass end to end against in-memory and temporary-file databases,
on both macOS (SQLite 3.51) and Linux (SQLite 3.45). The public surface is deliberately general — it
runs SQL and returns typed rows. Query building, models and migrations are concerns for code built
*on top* of the driver, not for the driver itself.

## Limitations

Deliberate scope choices, not bugs — most are the ORM's job, or a later release:

- **Positional parameters only** (`?`). Named parameters (`:name`, `$name`) aren't bound yet.
- **Scalar custom functions only** — `createFunction` registers scalar functions, not aggregates or
  window functions.
- **Integer types** are `Int` / `Int16` / `Int32` / `Int64` (mirroring perun-pgsql); a `UInt64`
  above `Int64.max` has no faithful SQLite integer representation.
- **One task per connection** — a `SQLiteConnection` isn't meant to be driven concurrently; use the
  pool (`SQLiteClient`) for that. See [the concurrency note](#a-note-on-concurrency).
- **No object mapping** — rows decode to Swift values, not to your model types. That mapping, query
  building, and migrations belong to a layer built on top.

## License

[MIT](LICENSE) © 2026 Anton Rudakov.
