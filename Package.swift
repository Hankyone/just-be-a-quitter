// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoQuitBackground",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "AutoQuitBackground",
            targets: ["AutoQuitBackground"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AutoQuitBackground"
        )
    ]
)
