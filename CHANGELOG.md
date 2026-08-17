# Changelog

All notable changes to perun-sqlite are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-08-18

### Changed

- Rename development targets to `PerunSQLiteDemo`, `PerunSQLiteExamples`, and
  `PerunSQLiteTests`; rename the demo executable product to `perun-sqlite-demo`.

## [0.1.3] - 2026-08-16

### Fixed

- Accept SQLite-compatible `24:xx` text dates and reject malformed time-zone offsets when
  decoding `Date`.

### Changed

- Document the best-effort, rowid-table-only and non-transactional semantics of `dataChanges`.

## [0.1.2] - 2026-07-11

### Fixed

- Reject out-of-range Julian-day `REAL` values when decoding `Date`, and clamp extreme `Date`
  values during non-throwing ISO-8601 encoding rather than trapping.

## [0.1.1] - 2026-07-11

### Fixed

- Roll back a transaction when its body swallowed task cancellation instead of committing it.
- Reject `Double.nan` in custom-function results and non-finite `REAL` values when decoding `Date`.

## [0.1.0] - 2026-07-10

Initial release: a thin, typed SQLite driver for Swift wrapping `libsqlite3`, mirroring the public
shape of perun-pgsql. Pre-1.0, so the API may still change.

### Added

- `SQLiteConnection` — an actor over one `sqlite3` handle; every libsqlite3 call runs on a
  per-connection serial queue, so a blocking `sqlite3_step` never stalls Swift's cooperative pool.
- `SQLiteClient` — a lazy, bounded connection pool with validate-on-borrow and age-based recycling.
- Parameterised queries (positional `?`), multi-statement `query(_:)`, and prepared statements
  (`prepare` / `execute` / `closePrepared`).
- `SQLiteValue` (the five storage classes) with `SQLiteDecodable` / `SQLiteEncodable` codecs for
  `Bool`, `Int`/`Int16`/`Int32`/`Int64`, `Float`/`Double`, `String`, `[UInt8]`/`Data`, `UUID`,
  `Date` (ISO-8601 / Unix / Julian), `Decimal`, and `SQLiteJSON`.
- Transactions (`withTransaction`; DEFERRED / IMMEDIATE / EXCLUSIVE), with BEGIN/COMMIT/ROLLBACK run
  uninterruptibly so a timed-out transaction still rolls back.
- Row streaming (`queryStream`) over `sqlite3_step`.
- `withTimeout` deadlines and task cancellation, both via `sqlite3_interrupt`.
- Typed errors: `PerunError`, `SQLiteError`, and `SQLiteResultCode` (primary + extended codes with
  class helpers such as `isConstraintViolation` / `isBusy`).
- SQLite-native extras: data-change hooks (`AsyncStream<SQLiteChange>`), online `backup(to:)`, and
  custom scalar SQL functions (`createFunction`).
- Configuration: file / `:memory:` / URI databases, read-only, `PRAGMA journal_mode` (WAL),
  `busy_timeout`, and `foreign_keys`.
- DocC documentation published to GitHub Pages; a runnable `perun-demo`; compile-checked
  `Examples/`; and a suite of 46 tests that runs entirely offline against in-memory databases,
  verified on macOS (SQLite 3.51) and Linux (SQLite 3.45).

[0.2.0]: https://github.com/tavvet/perun-sqlite/releases/tag/0.2.0
[0.1.3]: https://github.com/tavvet/perun-sqlite/releases/tag/0.1.3
[0.1.2]: https://github.com/tavvet/perun-sqlite/releases/tag/0.1.2
[0.1.1]: https://github.com/tavvet/perun-sqlite/releases/tag/0.1.1
[0.1.0]: https://github.com/tavvet/perun-sqlite/releases/tag/0.1.0
