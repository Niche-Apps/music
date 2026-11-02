// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StandardKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "StandardKit", targets: ["StandardKit"]),
        .library(name: "EngineProtocol", targets: ["EngineProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "EngineProtocol"),
        .target(
            name: "StandardKit",
            dependencies: [
                "EngineProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "StandardKitTests", dependencies: ["StandardKit"]),
        .executableTarget(name: "sm-dev", dependencies: ["StandardKit", "EngineProtocol"]),
    ]
)
