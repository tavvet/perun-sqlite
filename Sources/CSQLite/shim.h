#ifndef PERUN_CSQLITE_SHIM_H
#define PERUN_CSQLITE_SHIM_H

#include <sqlite3.h>

/*
 * SQLite's whole C API lives in <sqlite3.h>, and unlike OpenSSL it exposes almost
 * everything as real functions, so this shim only needs to pull the header into a
 * Clang module.
 *
 * The one awkward spot is the two special destructor sentinels passed to
 * sqlite3_bind_text/blob:
 *
 *   #define SQLITE_STATIC      ((sqlite3_destructor_type)0)
 *   #define SQLITE_TRANSIENT   ((sqlite3_destructor_type)-1)
 *
 * They are cast macros, so the Swift importer never sees them. The driver rebuilds
 * them in Swift with `unsafeBitCast` (see Concurrency.swift), so no wrapper is
 * needed here.
 */

#endif /* PERUN_CSQLITE_SHIM_H */
