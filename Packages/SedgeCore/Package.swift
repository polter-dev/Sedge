// swift-tools-version: 6.0
// Shared code for the iOS app: database, organizer, profile, simulator and tools.
import PackageDescription

let package = Package(
    name: "SedgeCore",
    // Strings instead of `.v27` so older PackageDescription versions still parse this file.
    // macOS is listed so `swift test` can run the tests on a Mac.
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "SedgeCore", targets: ["SedgeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0"),
    ],
    targets: [
        .target(name: "SedgeCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "SedgeCoreTests", dependencies: ["SedgeCore"]),
    ]
)
