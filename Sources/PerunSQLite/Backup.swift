import CSQLite

extension SQLiteConnection {
    /// Copy this database into `destination` using SQLite's online backup API.
    ///
    /// The embedded analogue of a bulk dump/load: it streams every page from this (source)
    /// database into `destination` in one call. Useful for snapshotting an in-memory database to
    /// disk, or vice versa (`try await onDisk.backup(to: inMemory)`).
    ///
    /// The whole copy runs on the *source* connection's queue and drives the backup against the
    /// destination's handle directly. Two requirements follow, and the caller must uphold them
    /// (they can't be fully enforced across two connections):
    /// - `destination` must be **exclusively owned** for the duration — no other operation may run
    ///   on it, or its queue and the source's queue would touch one `sqlite3 *` at once (safe only
    ///   under SQLite's default serialized threading; a data race otherwise). Typically it is a
    ///   connection opened just to receive the copy.
    /// - The source connection is likewise busy with the copy for the duration (its queue is
    ///   occupied), though *other* connections to the same file may keep reading it.
    ///
    /// - Parameters:
    ///   - destination: the connection to copy into.
    ///   - sourceName: the source schema (attached database) name, usually `"main"`.
    ///   - destinationName: the destination schema name, usually `"main"`.
    public func backup(to destination: SQLiteConnection,
                       sourceName: String = "main",
                       destinationName: String = "main") async throws {
        try ensureOpen()
        let destinationHandle = await destination.rawHandle()
        let source = handle

        try await withBlockingIO(on: ioQueue) {
            // Best-effort guard: refuse if either handle is already closed. (The destination flag
            // is set on *its* queue, so this narrows — doesn't eliminate — a concurrent-close race;
            // the "exclusively owned" contract above is what makes it safe.)
            guard !source.closed, !destinationHandle.closed else {
                throw PerunError.connectionClosed
            }
            guard let backup = sqlite3_backup_init(destinationHandle.db, destinationName,
                                                   source.db, sourceName) else {
                throw perunSQLiteError(destinationHandle.db)
            }
            let rc = sqlite3_backup_step(backup, -1)        // -1 = copy all remaining pages
            let finishRC = sqlite3_backup_finish(backup)
            guard rc == SQLITE_DONE else { throw perunSQLiteError(destinationHandle.db) }
            guard finishRC == SQLITE_OK else { throw perunSQLiteError(destinationHandle.db) }
            return ()
        }
    }

    /// The boxed database handle, for same-module coordination (e.g. `backup(to:)`).
    func rawHandle() -> SQLiteHandle { handle }
}
