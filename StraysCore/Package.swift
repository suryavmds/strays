// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StraysCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StraysCore", targets: ["StraysCore"]),
    ],
    targets: [
        .target(name: "StraysCore"),
        .testTarget(
            name: "StraysCoreTests",
            dependencies: ["StraysCore"]
        ),
    ]
)
