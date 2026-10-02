// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Donk",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Donk", targets: ["Donk"]),
        .library(name: "DonkCore", targets: ["DonkCore"]),
    ],
    targets: [
        .target(name: "DonkJSON"),
        .target(name: "DonkCore", dependencies: ["DonkJSON"]),
        .target(name: "DonkUI", dependencies: ["DonkJSON"]),
        .target(name: "DonkNetwork", dependencies: ["DonkCore"]),
        .target(name: "DonkNetworkUI", dependencies: ["DonkCore", "DonkUI"]),
        .target(name: "DonkWebView", dependencies: ["DonkCore"]),
        .target(name: "DonkInspector", dependencies: ["DonkCore", "DonkUI"]),
        .target(name: "DonkPerformance", dependencies: ["DonkCore", "DonkUI"]),
        .target(name: "DonkCrashC", publicHeadersPath: "include"),
        .target(name: "DonkCrash", dependencies: ["DonkCore", "DonkUI", "DonkCrashC"]),
        .target(name: "DonkPush", dependencies: ["DonkCore", "DonkUI"]),
        .target(
            name: "DonkStorage",
            dependencies: ["DonkCore", "DonkUI"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "Donk",
            dependencies: [
                "DonkJSON", "DonkCore", "DonkUI", "DonkNetwork", "DonkNetworkUI", "DonkWebView",
                "DonkInspector", "DonkPerformance", "DonkCrash", "DonkPush", "DonkStorage",
            ]
        ),
        .testTarget(name: "DonkJSONTests", dependencies: ["DonkJSON"]),
        .testTarget(name: "DonkCoreTests", dependencies: ["DonkCore"]),
        .testTarget(name: "DonkNetworkTests", dependencies: ["DonkNetwork"]),
        .testTarget(name: "DonkPerformanceTests", dependencies: ["DonkPerformance"]),
        .testTarget(name: "DonkCrashTests", dependencies: ["DonkCrash"]),
        .testTarget(name: "DonkPushTests", dependencies: ["DonkPush"]),
        .testTarget(name: "DonkStorageTests", dependencies: ["DonkStorage"]),
    ]
)
