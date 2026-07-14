// swift-tools-version: 6.2
import PackageDescription
import Foundation

// External swift-testing 6.3 needs the toolchain's private test-discovery bridge when
// SwiftPM is driven by Command Line Tools. Resolve the active developer directory instead
// of baking in one Xcode installation path so local CLT and DEVELOPER_DIR-based CI agree.
let testingInteropLibraryPath: String = {
    if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
       !developerDirectory.isEmpty
    {
        return "\(developerDirectory)/Library/Developer/usr/lib"
    }

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = output
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let directory = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !directory.isEmpty {
                return "\(directory)/Library/Developer/usr/lib"
            }
        }
    } catch {}
    return "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
}()

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
        // pre-1.0 swift-testing can false-green binary #expect expressions under
        // newer compilers. Pin the version that matches the current Swift 6.3 CLT.
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.3.2")
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
            ],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-L", testingInteropLibraryPath,
                        "-Xlinker", "-rpath",
                        "-Xlinker", testingInteropLibraryPath,
                    ],
                    .when(platforms: [.macOS])
                )
            ]
        )
    ]
)
