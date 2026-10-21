// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SimpleCodexBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexUsageCore", targets: ["CodexUsageCore"]),
    ],
    targets: [
        .target(name: "CodexUsageCore", resources: [.process("Resources")]),
        .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"]),
    ]
)
