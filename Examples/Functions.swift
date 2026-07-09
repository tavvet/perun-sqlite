import PerunSQLite
import Foundation

func runFunctions() async throws {
    let connection = try await openMemoryConnection()

    // A deterministic scalar function, usable anywhere SQL expects one.
    try await connection.createFunction("levenshtein_le", argumentCount: 3, deterministic: true) { args in
        guard case let .text(a) = args[0], case let .text(b) = args[1],
              case let .integer(limit) = args[2] else { return .null }
        return .integer(editDistance(a, b) <= Int(limit) ? 1 : 0)
    }

    try await connection.query("CREATE TABLE words (w TEXT)")
    for word in ["swift", "swiff", "rust", "strong"] {
        try await connection.query("INSERT INTO words VALUES (?)", [word])
    }

    let matches = try await connection.query(
        "SELECT w FROM words WHERE levenshtein_le(w, ?, ?) = 1 ORDER BY w", ["swift", 1])
    let found = try matches.rows.map { try $0.decode("w", as: String.self) }
    print("within edit distance 1 of 'swift': \(found)")

    try await connection.close()
}

private func editDistance(_ s1: String, _ s2: String) -> Int {
    let a = Array(s1), b = Array(s2)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var dp = Array(0...b.count)                       // distance of "" to each prefix of b
    for i in 1...a.count {
        var diagonal = dp[0]                          // dp[i-1][j-1]
        dp[0] = i
        for j in 1...b.count {
            let above = dp[j]                         // dp[i-1][j]
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            dp[j] = min(dp[j] + 1, dp[j - 1] + 1, diagonal + cost)
            diagonal = above
        }
    }
    return dp[b.count]
}
