# Transactions

Running several statements atomically.

## withTransaction

``SQLiteConnection/withTransaction(kind:_:)`` issues `BEGIN`, runs your closure, and `COMMIT`s — or
`ROLLBACK`s if the closure throws:

```swift
try await connection.withTransaction { tx in
    try await tx.query("UPDATE accounts SET balance = balance - ? WHERE id = ?", [amount, from])
    try await tx.query("UPDATE accounts SET balance = balance + ? WHERE id = ?", [amount, to])
}
```

The closure receives a ``SQLiteConnection/Transaction`` handle. Run statements through **it**
(`tx.query`, `tx.prepare`, `tx.execute`) so they land inside the transaction.

## Transaction kinds

Pass a ``TransactionKind`` to choose when the lock is taken:

- ``TransactionKind/deferred`` (default) — lock on first read or write.
- ``TransactionKind/immediate`` — take a write lock at `BEGIN`, so a competing writer fails fast
  rather than at `COMMIT`.
- ``TransactionKind/exclusive`` — take an exclusive lock immediately.

```swift
try await connection.withTransaction(kind: .immediate) { tx in … }
```

## Rollback and cancellation

The transaction rolls back — never commits partial work — when the closure throws, the task is
cancelled, or a wrapping ``withTimeout(_:_:)`` fires. `BEGIN`/`COMMIT`/`ROLLBACK` run uninterruptibly,
so a timed-out transaction still rolls back cleanly and leaves the connection reusable.

SQLite has no nested transactions: calling `withTransaction` again while one is open throws (the
nested `BEGIN` is rejected), but the outer transaction is left intact. Use `SAVEPOINT` SQL if you
need nesting.

## On a pool

``SQLiteClient/withTransaction(kind:_:)`` does the same on a pooled connection — it checks one out,
runs the transaction, and returns it only after `COMMIT`/`ROLLBACK` completes:

```swift
try await pool.withTransaction { tx in
    try await tx.query("INSERT INTO audit (event) VALUES (?)", [event])
}
```
