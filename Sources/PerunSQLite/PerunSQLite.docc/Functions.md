# Custom SQL functions

Calling Swift from SQL.

## createFunction

``SQLiteConnection/createFunction(_:argumentCount:deterministic:_:)`` registers a scalar SQL function
implemented in Swift. It becomes callable from SQL on that connection — a staple of embedded SQLite
use, and one with no PostgreSQL-driver analogue (there, functions live in the server).

```swift
try await connection.createFunction("initials", argumentCount: 1, deterministic: true) { args in
    guard case let .text(name) = args[0] else { return .null }
    return .text(name.split(separator: " ").compactMap(\.first).map(String.init).joined())
}

let who = try await connection.query("SELECT initials('Ada Lovelace') AS i")
    .first?.decode("i", as: String.self)     // "AL"
```

The closure receives the arguments as ``SQLiteValue``s and returns one — so it composes with the
same storage classes the rest of the driver uses. It's usable anywhere SQL expects a scalar,
including `WHERE` and `ORDER BY`.

## Parameters

- **`argumentCount`** — the exact arity, or `nil` for variadic (any number of arguments). SQLite
  requires an arity of `0…127`; anything else throws ``PerunError/invalidArgumentCount(_:)``.
- **`deterministic`** — set `true` when the function returns the same result for the same inputs. It
  lets SQLite use the function in more contexts, such as indexes on expressions.

## Errors

Throwing from the closure surfaces to SQL as a function error, which propagates back as a
``PerunError/sqlite(_:)``:

```swift
try await connection.createFunction("must_be_positive", argumentCount: 1) { args in
    guard case let .integer(n) = args[0], n > 0 else {
        throw MyError.notPositive
    }
    return .integer(n)
}
```
