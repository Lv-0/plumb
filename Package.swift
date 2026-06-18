// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Plumb",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "Plumb",
            targets: ["Plumb"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Plumb"
        ),
        .testTarget(
            name: "PlumbTests",
            dependencies: [
                "Plumb",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
