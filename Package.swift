// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snowpuff",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Snowpuff",
            path: "Sources/Snowpuff"
        ),
    ]
)
