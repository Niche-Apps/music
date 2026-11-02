// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YuEKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "YuEKit", targets: ["YuEKit"]),
        .executable(name: "yue-cli", targets: ["yue-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
    ],
    targets: [
        .target(
            name: "YuEKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),
        .executableTarget(name: "yue-cli", dependencies: ["YuEKit"]),
    ]
)
