// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Respool",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Respool",
            path: "Sources/Respool",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
