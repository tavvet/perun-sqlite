// swift-tools-version:6.0
import PackageDescription
import Foundation

// swift-docc-plugin is pulled in only for documentation builds (set PERUN_BUILD_DOCS=1, as
// Scripts/build-docs.sh does), so a normal build — and anyone depending on this package — never
// carries a docs tool in its dependency graph.
var packageDependencies: [Package.Dependency] = []
if ProcessInfo.processInfo.environment["PERUN_BUILD_DOCS"] != nil {
    packageDependencies.append(.package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"))
}

let package = Package(
    name: "PerunSQLite",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PerunSQLite", targets: ["PerunSQLite"]),
        .executable(name: "perun-sqlite-demo", targets: ["PerunSQLiteDemo"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // C-interop shim exposing libsqlite3 to Swift. SQLite is located through pkg-config, so
        // this package carries no unsafe build flags and can be used as a normal dependency. On
        // macOS sqlite3.h and libsqlite3 ship with the SDK, so it builds out of the box; on
        // Debian/Ubuntu install `libsqlite3-dev`.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.brew(["sqlite3"]), .apt(["libsqlite3-dev"])]
        ),

        // The driver itself — pure Swift + libsqlite3. No sockets, no TLS: SQLite is embedded.
        .target(
            name: "PerunSQLite",
            dependencies: ["CSQLite"]
        ),

        // A tiny runnable program that opens a database and runs queries.
        .executableTarget(
            name: "PerunSQLiteDemo",
            dependencies: ["PerunSQLite"]
        ),

        // Runnable, compile-checked examples that back the documentation. `swift build` compiles
        // them, so a doc example can't drift from the real API.
        .executableTarget(
            name: "PerunSQLiteExamples",
            dependencies: ["PerunSQLite"],
            path: "Examples"
        ),

        // Unit tests for the value model, type codecs, result rows and error classification.
        // They run entirely against in-memory databases — no external server needed.
        .testTarget(
            name: "PerunSQLiteTests",
            dependencies: ["PerunSQLite"]
        ),
    ]
)
