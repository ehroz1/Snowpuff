// swift-tools-version:5.9
import PackageDescription

/// Where build.sh puts the Rust library the app links: the rooms for snowball fights (net/) and Snowpuff's own
/// extras, icicles and sounds (core/), built for both architectures.
let rust = Context.packageDirectory + "/build/rust"

let package = Package(
    name: "Snowpuff",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CSnowpuffNet", path: "Sources/CSnowpuffNet"),
        .executableTarget(
            name: "Snowpuff",
            dependencies: ["CSnowpuffNet"],
            path: "Sources/Snowpuff",
            // The per-frame loops reach class properties millions of times a second; Swift's runtime exclusivity
            // checks around each access cost as much as the physics itself.
            swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))],
            linkerSettings: [
                .unsafeFlags(["-L", rust]),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
