import CSQLite

/// Retains a custom-function closure so the C callbacks can reach it through `sqlite3_user_data`.
/// `@unchecked Sendable` because the closure is `@Sendable` and SQLite invokes it serially on the
/// connection's queue.
final class FunctionBox: @unchecked Sendable {
    let implementation: @Sendable ([SQLiteValue]) throws -> SQLiteValue
    init(_ implementation: @escaping @Sendable ([SQLiteValue]) throws -> SQLiteValue) {
        self.implementation = implementation
    }
}

extension SQLiteConnection {
    /// Register a scalar SQL function implemented in Swift.
    ///
    /// The function becomes callable from SQL on this connection. It has no analogue in the
    /// PostgreSQL driver (there, functions live in the server), but it is a staple of embedded
    /// SQLite use — e.g. exposing a Swift comparison, hash, or formatting routine to `WHERE` /
    /// `ORDER BY`.
    ///
    /// ```swift
    /// try await connection.createFunction("reverse", argumentCount: 1) { args in
    ///     guard case let .text(s) = args[0] else { return .null }
    ///     return .text(String(s.reversed()))
    /// }
    /// let flipped = try await connection.query("SELECT reverse('abc') AS r")
    /// ```
    ///
    /// - Parameters:
    ///   - name: the SQL function name.
    ///   - argumentCount: the exact number of arguments, or `nil` for variadic (any arity).
    ///   - deterministic: whether the function returns the same result for the same inputs (lets
    ///     SQLite use it in more contexts, e.g. indexes on expressions).
    ///   - directOnly: when `true` (the default, and SQLite's recommendation for app-defined
    ///     functions) the function may be called only from top-level SQL — not from triggers,
    ///     views, `CHECK` constraints, `DEFAULT` clauses, index expressions, or generated columns.
    ///     That stops a maliciously crafted database file from invoking your Swift code through
    ///     schema it embeds. Set it `false` if you deliberately need the function in those places.
    ///   - implementation: maps the argument values to a result. Throwing surfaces to SQL as a
    ///     function error.
    public func createFunction(
        _ name: String,
        argumentCount: Int? = nil,
        deterministic: Bool = false,
        directOnly: Bool = true,
        _ implementation: @escaping @Sendable ([SQLiteValue]) throws -> SQLiteValue
    ) async throws {
        try ensureOpen()
        // SQLite's C API requires nArg ∈ [-1, 127]; anything else is undefined behavior (and a
        // value above Int32.max would even trap Int32.init). Validate before touching C.
        if let argumentCount, !(0 ... 127).contains(argumentCount) {
            throw PerunError.invalidArgumentCount(argumentCount)
        }
        let box = FunctionBox(implementation)
        let db = handle
        let functionName = name
        let argCount = argumentCount.map { Int32($0) } ?? -1      // now guaranteed 0…127 or -1 (variadic)
        let isDeterministic = deterministic
        let isDirectOnly = directOnly

        try await withBlockingIO(on: ioQueue) {
            guard !db.closed else { throw PerunError.connectionClosed }
            // Hand ownership of the box to SQLite; the xDestroy callback releases it (on close, on
            // replacement, or if registration fails).
            let context = Unmanaged.passRetained(box).toOpaque()
            var flags = SQLITE_UTF8
            if isDeterministic { flags |= SQLITE_DETERMINISTIC }
            if isDirectOnly { flags |= SQLITE_DIRECTONLY }
            let rc = sqlite3_create_function_v2(
                db.db, functionName, argCount, flags, context,
                { context, argumentCount, arguments in
                    perunInvokeFunction(context, argumentCount, arguments)
                },
                nil,        // xStep (aggregate) — scalar only
                nil,        // xFinal (aggregate) — scalar only
                { context in perunReleaseFunctionBox(context) }
            )
            // Read the error on the queue while the handle is guaranteed live — not after the hop
            // back to the actor, where a concurrent close() may have freed it. create_function_v2
            // already invoked xDestroy (releasing the box) on failure.
            guard rc == SQLITE_OK else { throw perunSQLiteError(db.db) }
            return ()
        }
    }
}

// MARK: - C trampolines

/// The xFunc callback: read the argument values, run the Swift closure, set the result.
private func perunInvokeFunction(_ context: OpaquePointer?,
                                 _ argumentCount: Int32,
                                 _ arguments: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let context, let boxPointer = sqlite3_user_data(context) else { return }
    let box = Unmanaged<FunctionBox>.fromOpaque(boxPointer).takeUnretainedValue()

    var values: [SQLiteValue] = []
    values.reserveCapacity(Int(argumentCount))
    if let arguments {
        for index in 0 ..< Int(argumentCount) {
            values.append(perunValue(from: arguments[index]))
        }
    }

    do {
        perunSetResult(context, try box.implementation(values))
    } catch {
        let message = String(describing: error)
        message.withCString { sqlite3_result_error(context, $0, -1) }
    }
}

/// The xDestroy callback: release the retained function box.
private func perunReleaseFunctionBox(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<FunctionBox>.fromOpaque(pointer).release()
}

/// Read a `sqlite3_value *` argument into a `SQLiteValue`.
private func perunValue(from value: OpaquePointer?) -> SQLiteValue {
    guard let value else { return .null }
    switch sqlite3_value_type(value) {
    case SQLITE_INTEGER:
        return .integer(sqlite3_value_int64(value))
    case SQLITE_FLOAT:
        return .real(sqlite3_value_double(value))
    case SQLITE_TEXT:
        let count = Int(sqlite3_value_bytes(value))
        if count > 0, let pointer = sqlite3_value_text(value) {
            return .text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
        }
        return .text("")
    case SQLITE_BLOB:
        let count = Int(sqlite3_value_bytes(value))
        if count > 0, let pointer = sqlite3_value_blob(value) {
            return .blob(Array(UnsafeRawBufferPointer(start: pointer, count: count)))
        }
        return .blob([])
    default:
        return .null
    }
}

/// Set a `SQLiteValue` as a function's result.
private func perunSetResult(_ context: OpaquePointer, _ value: SQLiteValue) {
    switch value {
    case .null:
        sqlite3_result_null(context)
    case let .integer(value):
        sqlite3_result_int64(context, value)
    case let .real(value):
        // Match the bind path: SQLite has no NaN in a REAL cell, so sqlite3_result_double would
        // silently return SQL NULL. Surface a function error instead. (±Infinity is fine.)
        if value.isNaN {
            "function returned Double.nan, which SQLite cannot represent as REAL"
                .withCString { sqlite3_result_error(context, $0, -1) }
        } else {
            sqlite3_result_double(context, value)
        }
    case let .text(string):
        var string = string
        string.withUTF8 { buffer in
            // _64 length is UInt64, so a >2 GiB result returns an error instead of trapping Int32.
            if let base = buffer.baseAddress {
                sqlite3_result_text64(context,
                                      UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self),
                                      UInt64(buffer.count), SQLITE_TRANSIENT, UInt8(SQLITE_UTF8))
            } else {
                sqlite3_result_text64(context, "", 0, SQLITE_TRANSIENT, UInt8(SQLITE_UTF8))
            }
        }
    case let .blob(bytes):
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                // An empty array can yield a nil base pointer, and result_blob(NULL, 0) sets SQL
                // NULL, not an empty BLOB. Use a valid zero-length pointer (mirrors perunBindBlob).
                sqlite3_result_blob64(context, "", 0, SQLITE_TRANSIENT)
                return
            }
            sqlite3_result_blob64(context, base, UInt64(raw.count), SQLITE_TRANSIENT)
        }
    }
}
