# Architecture

How the driver is put together: the layers, the concurrency model, and what it leaves to a higher
layer.

## Layers

```
your code
   │
   ▼
SQLiteClient          — a pool of connections (this is where concurrency comes from)
   │
   ▼
SQLiteConnection      — an actor: one sqlite3 handle and its statement state
   │
   ▼
withBlockingIO        — a per-connection serial dispatch queue
   │
   ▼
libsqlite3            — the embedded engine (blocking C calls)
```

SQLite is embedded, so there is no wire protocol, authentication, or TLS beneath the connection — the
transport bottom half of a client/server driver is simply absent. What's left is a thin, typed
wrapper: the driver binds parameters, steps statements, and reads back ``SQLiteValue``s. Only the type
layer imports Foundation (for `UUID` / `Date` / `Data` / `Decimal`).

## Concurrency

A ``SQLiteConnection`` is an `actor`, so its statement registry and stream state are isolated. Every
`libsqlite3` call runs on the connection's single serial dispatch queue via `withBlockingIO`, so a
blocking `sqlite3_step` (which can wait on a busy lock) never parks a thread from Swift's cooperative
pool. The non-`Sendable` C pointers are held in `@unchecked Sendable` boxes, sound because every call
for a connection runs on that one queue.

Unlike the PostgreSQL driver there is **no wire lock** — there is no shared wire, and no pipelining to
gain from one. A connection serialises its calls but is meant for one logical task at a time; real
concurrency comes from running many connections, which is what ``SQLiteClient`` is for. A "closed"
flag lives on the queue too, so a `close()` that races an in-flight operation can't free the handle
out from under it.

## Cancellation

A cancelled operation (directly, or via ``withTimeout(_:_:)``) fires `sqlite3_interrupt`, so a blocked
`sqlite3_step` returns promptly and the caller sees `CancellationError` / ``PerunError/timedOut``. A
generation guard keeps a late cancel from touching a later statement. Transaction control
(`BEGIN`/`COMMIT`/`ROLLBACK`) runs uninterruptibly, so a timed-out transaction still rolls back.

## Lifecycles

- **Connection** — `connect` opens the handle, enables extended result codes, and applies the
  configured pragmas (journal mode, busy timeout, foreign keys). ``SQLiteConnection/close()`` — or, as
  a safety net, deallocation — finalises statements and closes the handle.
- **Query** — each statement is compiled, stepped to completion, and finalised within one queue block.
- **Pool** — connections open lazily up to a bound, are validated on borrow, optionally recycled by
  age, and closed on `shutdown()`. See <doc:ConnectionPool> and <doc:ErrorsAndRecovery>.

## What it leaves out

PerunSQLite is a **data-access driver**. It moves rows and values; it does not build SQL, map tables
onto model types, or run migrations. Those belong to a higher layer built on top of it — the driver's
job is to be a correct, predictable foundation for one.
