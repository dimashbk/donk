// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Donk",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Donk", targets: ["Donk"]),
        .library(name: "DonkCore", targets: ["DonkCore"]),
        .library(name: "DonkGRPC", targets: ["DonkGRPC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", "1.21.0"..<"2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.58.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.26.0"),
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
        .target(
            name: "DonkGRPC",
            dependencies: [
                "DonkCore",
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            ]
        ),
        .testTarget(
            name: "DonkGRPCTests",
            dependencies: [
                "DonkGRPC",
                "DonkCore",
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            ],
            exclude: ["Protos"]
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
