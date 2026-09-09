// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "meter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "meter",
            path: "Sources/meter",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "MeterTests", dependencies: ["meter"], path: "Tests/MeterTests")
    ]
)
