// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoringKit",
    platforms: [.iOS(.v16)],
    products: [.library(name: "BoringKit", targets: ["BoringKit"])],
    dependencies: [
        .package(url: "https://github.com/kstenerud/KSCrash.git", .upToNextMinor(from: "2.6.1")),
        // exact: the device token rides in Aptabase's App-Key, which relies on how 0.4.0 parses it
        .package(url: "https://github.com/aptabase/aptabase-swift.git", exact: "0.4.0"),
    ],
    targets: [
        .target(
            name: "BoringKit",
            dependencies: [
                .product(name: "Recording", package: "KSCrash"),
                .product(name: "Monitors", package: "KSCrash"),
                .product(name: "Aptabase", package: "aptabase-swift"),
            ]
        ),
        .testTarget(name: "BoringKitTests", dependencies: ["BoringKit"]),
    ]
)
