// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SimpleCodexBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexUsageCore", targets: ["CodexUsageCore"]),
        .executable(name: "SimpleCodexBar", targets: ["SimpleCodexBar"])
    ],
    targets: [
        .target(name: "CodexUsageCore", resources: [.process("Resources")]),
        .executableTarget(name: "SimpleCodexBar", dependencies: ["CodexUsageCore"]),
        .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"]),
    ]
)
