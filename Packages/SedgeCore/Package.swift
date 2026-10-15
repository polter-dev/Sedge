// swift-tools-version: 6.0
// Shared code for the iOS app and the macOS command-line tools.
import PackageDescription

let package = Package(
    name: "SedgeCore",
    // Strings instead of `.v27` so older PackageDescription versions still parse this file.
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "SedgeCore", targets: ["SedgeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0"),
    ],
    targets: [
        .target(name: "SedgeCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // Asks one question about one persona and prints the trace (debugging only).
        .executableTarget(name: "sedge-ask", dependencies: ["SedgeCore"]),
        // Runs the question bank through one configuration and saves every answer, prints one
        // persona's profile facts with `profile --persona <name>`, or writes the balance
        // backtest with `backtest --cutoff ...` (macOS only).
        .executableTarget(name: "sedge-eval", dependencies: ["SedgeCore"]),
        .testTarget(name: "SedgeCoreTests", dependencies: ["SedgeCore", "sedge-eval"]),
    ]
)
