/// A result set read lazily, one row at a time, instead of buffering the whole thing in memory.
/// Obtained from `SQLiteConnection.queryStream(_:_:)` and consumed with `for try await`:
///
/// ```swift
/// for try await row in try await connection.queryStream("SELECT id FROM big_table") {
///     process(try row.decode("id", as: Int.self))
/// }
/// ```
///
/// Each `for await` step runs one `sqlite3_step`, so a large result never all lives in memory at
/// once, and a slow consumer simply steps more slowly. Stopping early (a `break`, an error, or
/// dropping the stream) finalizes the underlying statement and frees it.
///
/// Unlike the PostgreSQL driver's stream, this does not seize an exclusive wire lock — there is no
/// wire. A `SQLiteConnection` serializes its calls, and is intended for one logical task at a
/// time; keep iterating a stream (and don't fire other writes on the *same* connection mid-stream)
/// until it ends. Use the pool (`SQLiteClient`) for concurrency.
public struct SQLiteRowStream: AsyncSequence, Sendable {
    public typealias Element = SQLiteRow

    let connection: SQLiteConnection
    let generation: UInt64
    private let cleanup: StreamCleanup

    init(connection: SQLiteConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
        self.cleanup = StreamCleanup(connection: connection, generation: generation)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(connection: connection, generation: generation, cleanup: cleanup)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let connection: SQLiteConnection
        let generation: UInt64
        let cleanup: StreamCleanup      // retained for the iterator's lifetime; frees the statement on drop

        public mutating func next() async throws -> SQLiteRow? {
            try await connection.nextStreamRow(generation: generation)
        }
    }
}

/// Finalizes a stream that the consumer abandoned before it finished. When the last reference to
/// the stream and its iterator is dropped — a `break` out of the loop, or simply letting them go —
/// this `deinit` asks the connection to finalize the statement. A stream consumed to its end has
/// already cleaned up, so the connection call is an idempotent no-op (guarded by the generation).
final class StreamCleanup: @unchecked Sendable {
    private let connection: SQLiteConnection
    private let generation: UInt64      // the stream this cleanup belongs to; a stale deinit is a no-op

    init(connection: SQLiteConnection, generation: UInt64) {
        self.connection = connection
        self.generation = generation
    }

    deinit {
        let connection = self.connection
        let generation = self.generation
        Task { await connection.finishStream(generation: generation) }
    }
}
