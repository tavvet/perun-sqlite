import CSQLite

extension SQLiteConnection {
    /// Copy this database into `destination` using SQLite's online backup API.
    ///
    /// The embedded analogue of a bulk dump/load: it streams every page from this (source)
    /// database into `destination` in one call. Useful for snapshotting an in-memory database to
    /// disk, or vice versa (`try await onDisk.backup(to: inMemory)`).
    ///
    /// The backup runs on the source connection's queue and touches the destination handle
    /// directly, so `destination` must not be used concurrently for the duration — typically it is
    /// a connection opened just to receive the copy. The source may keep being read; SQLite copies
    /// a consistent snapshot.
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
