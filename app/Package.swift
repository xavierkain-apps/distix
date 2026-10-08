// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DistiX",
    defaultLocalization: "fr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DistiXCore", targets: ["DistiXCore"]),
        .executable(name: "DistiX", targets: ["DistiX"]),
        .executable(name: "distix-cli", targets: ["distix-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "DistiXCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/prompts")]
        ),
        .executableTarget(
            name: "DistiX",
            dependencies: ["DistiXCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "distix-cli", dependencies: ["DistiXCore"]),
        .testTarget(name: "DistiXCoreTests", dependencies: ["DistiXCore"]),
    ]
)
