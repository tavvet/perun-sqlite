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
    ///   on it. The copy drives the destination handle from the *source's* queue, so a concurrent
    ///   operation on the destination would touch one `sqlite3 *` from two threads at once — a data
    ///   race (this package links the system libsqlite3, which on Apple platforms is built
    ///   multi-thread, not serialized, so there is no per-connection mutex to fall back on).
    ///   Typically the destination is a connection opened just to receive the copy.
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
            var rc = sqlite3_backup_step(backup, -1)        // -1 = copy all remaining pages
            // BUSY/LOCKED from backup_step are transient (a writer holds the source lock as the copy
            // starts); the step can simply be retried. Bound the retries so a stuck lock can't hang.
            var attempts = 0
            while rc == SQLITE_BUSY || rc == SQLITE_LOCKED, attempts < 50 {
                sqlite3_sleep(100)                          // ms
                rc = sqlite3_backup_step(backup, -1)
                attempts += 1
            }
            let finishRC = sqlite3_backup_finish(backup)
            guard rc == SQLITE_DONE else { throw perunSQLiteError(destinationHandle.db) }
            guard finishRC == SQLITE_OK else { throw perunSQLiteError(destinationHandle.db) }
            return ()
        }
    }

    /// The boxed database handle, for same-module coordination (e.g. `backup(to:)`).
    func rawHandle() -> SQLiteHandle { handle }
}
