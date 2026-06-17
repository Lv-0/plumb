// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "centerWindows",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "centerWindows",
            targets: ["centerWindows"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "centerWindows"
        ),
        .testTarget(
            name: "centerWindowsTests",
            dependencies: [
                "centerWindows",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
