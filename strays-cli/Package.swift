// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "strays-cli",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../StraysCore"),
    ],
    targets: [
        .executableTarget(
            name: "strays",
            dependencies: ["StraysCore"]
        ),
    ]
)
