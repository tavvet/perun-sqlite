# Decoding and encoding

How Swift values map to and from SQLite's storage classes.

## SQLite values are typed

SQLite is dynamically typed: every value is in one of five storage classes — `NULL`, `INTEGER`,
`REAL`, `TEXT`, `BLOB`. Unlike a wire protocol that delivers raw bytes tagged with a type, the engine
hands back an already-typed value, so this driver carries it typed all the way to decoding as a
``SQLiteValue``. A ``SQLiteCell`` wraps one; ``SQLiteValue/storageClass`` tells you which class it holds.

## Decoding

Decode a cell into a Swift type with ``SQLiteCell/decode(_:)`` (throws on `NULL`, a missing column,
or a type mismatch) or ``SQLiteCell/decodeIfPresent(_:)`` (returns `nil` on SQL `NULL`). ``SQLiteRow``
forwards both by column name or index:

```swift
let id   = try row.decode("id", as: Int.self)
let note = try row.decodeIfPresent("note", as: String.self)
let flag = try row[2].decode(Bool.self)
```

Built-in ``SQLiteDecodable`` conformances cover `Bool`, the `Int` family, `Float`/`Double`, `String`,
`[UInt8]` and `Data` (BLOB), plus, from Foundation, `UUID`, `Date`, and `Decimal`, and the
``SQLiteJSON`` wrapper. Decoders coerce leniently where it's sensible (an `INTEGER` into a `Double`,
a `TEXT` number into an `Int`) but reject a lossy conversion rather than silently truncate.

## Encoding

Bound parameters implement ``SQLiteEncodable`` — a value maps itself onto a ``SQLiteValue``, which the
driver binds with the matching `sqlite3_bind_*` call. The same built-in types conform. A `nil`
element in a parameter array is SQL `NULL`.

Some types have no native SQLite representation, so they follow a documented convention:

- **`Date`** encodes to ISO-8601 `TEXT`; it decodes from `TEXT`, from `INTEGER` (Unix seconds), or
  from `REAL` (a Julian day, as `julianday()` produces).
- **`UUID`** encodes to `TEXT`; it also decodes from a 16-byte `BLOB`.
- **`Decimal`** encodes to `TEXT`, to preserve exact precision.
- **``SQLiteJSON``** is a thin `TEXT` wrapper (SQLite stores JSON as text).

## Custom types

Conform your own types to encode and decode directly — for example an enum stored as `TEXT`:

```swift
enum Priority: String, SQLiteEncodable, SQLiteDecodable {
    case low, medium, high
    func encode() -> SQLiteValue { .text(rawValue) }
    static func decode(from value: SQLiteValue) throws -> Priority {
        guard case let .text(s) = value, let p = Priority(rawValue: s) else {
            throw PerunError.decodingFailed(
                type: "Priority", storageClass: value.storageClass.description, reason: "unknown")
        }
        return p
    }
}
```

For full control of the exact storage class, ``SQLiteValue`` is itself ``SQLiteEncodable`` — bind one
directly.
