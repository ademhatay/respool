// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Raf",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Raf",
            path: "Sources/Raf",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
