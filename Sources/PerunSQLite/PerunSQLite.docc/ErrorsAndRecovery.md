# Errors and recovery

The error model, branching on result codes, and keeping a connection usable.

## The error types

Everything the driver throws is a ``PerunError``. A failure reported by the SQLite engine arrives as
``PerunError/sqlite(_:)`` wrapping a ``SQLiteError``, which pairs a typed ``SQLiteResultCode`` with
the raw code and message. Reach the engine error without unwrapping the case by hand via
``PerunError/sqliteError``:

```swift
do {
    try await connection.query("INSERT INTO users (email) VALUES (?)", [email])
} catch let error as PerunError {
    if error.sqliteError?.resultCode == .constraintUnique {
        // that email is already taken
    }
}
```

## Branch on the result code, not the message

``SQLiteResultCode`` names the codes callers commonly branch on — both primary codes (`.busy`,
`.readonly`, …) and the extended constraint codes (``SQLiteResultCode/constraintUnique``,
``SQLiteResultCode/constraintForeignKey``, ``SQLiteResultCode/constraintNotNull``, …). It is the
stable signal; the human-readable `message` is not, so never parse it. Class helpers cover whole
groups:

```swift
switch error.sqliteError?.resultCode {
case .constraintUnique:    …
case .constraintNotNull:   …
case let code? where code.isBusy:  … // busy or locked — a transient conflict worth retrying
default: break
}
```

Any code the driver doesn't name is ``SQLiteResultCode/other(_:)``, preserving the raw integer;
``SQLiteResultCode/primaryCode`` gives the primary code behind an extended one.

## The connection stays usable

An ordinary error — a constraint violation, a type mismatch, a decode failure — leaves the connection
perfectly usable, so a pool keeps it. Only a handful of failures (corruption, an I/O error, an
unreadable file) suggest the handle is in a doubtful state, and a pool discards and replaces it after
those. So you can catch a constraint violation and keep querying on the same connection.

## Timeouts and cancellation

Wrap any operation in ``withTimeout(_:_:)`` to bound it. On a timeout the running statement is
interrupted (`sqlite3_interrupt`), the call throws ``PerunError/timedOut``, and the connection is left
reusable:

```swift
let rows = try await withTimeout(.seconds(5)) {
    try await connection.query("SELECT * FROM big_report").rows
}
```

The same mechanism backs task cancellation — a cancelled query is interrupted and throws
`CancellationError`. ``SQLiteConnection/interrupt()`` asks the engine to abort the statement currently
running on a connection, so another task can stop a long query.
