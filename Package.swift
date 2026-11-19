// swift-tools-version:5.9
import Foundation
import PackageDescription

// build.sh builds the Rust core for both Mac architectures into this folder first.
let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("core/target/universal").path

let package = Package(
    name: "Snowpuff",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSnowpuffCore", path: "Sources/CSnowpuffCore"),
        .executableTarget(
            name: "Snowpuff",
            dependencies: ["CSnowpuffCore"],
            path: "Sources/Snowpuff",
            linkerSettings: [.unsafeFlags(["-L", core, "-lsnowpuff_core"])]
        ),
    ]
)
