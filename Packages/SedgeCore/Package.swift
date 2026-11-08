// swift-tools-version: 6.0
// Shared code for the iOS app: database, organizer, profile, simulator, tools and the on-device model.
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
        // The on-device model (Qwen3.5-4B, 4-bit) runs with MLX. swift-transformers reads its tokenizer,
        // and swift-jinja renders its chat template directly, so the tools keep the key order the benchmark sent.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.4.0"),
        .package(url: "https://github.com/huggingface/swift-jinja", from: "3.0.0"),
    ],
    targets: [
        .target(name: "SedgeCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "Jinja", package: "swift-jinja"),
        ]),
        .testTarget(name: "SedgeCoreTests", dependencies: ["SedgeCore", .product(name: "Jinja", package: "swift-jinja")]),
    ]
)
