import PerunSQLite

// Runnable, compile-checked examples that back the documentation. Run one with
// `swift run PerunSQLiteExamples <scenario>`. Every scenario uses an in-memory or temporary-file database, so
// none of them needs an external server.

let scenario = CommandLine.arguments.dropFirst().first ?? ""
switch scenario {
case "basic-query":    try await runBasicQuery()
case "transactions":   try await runTransactions()
case "streaming":      try await runStreaming()
case "pool":           try await runPool()
case "error-handling": try await runErrorHandling()
case "custom-type":    try await runCustomType()
case "functions":      try await runFunctions()
case "backup":         try await runBackup()
case "hooks":          try await runHooks()
default:
    print("usage: swift run PerunSQLiteExamples <scenario>")
    print("scenarios: basic-query, transactions, streaming, pool, error-handling, custom-type, functions, backup, hooks")
}
