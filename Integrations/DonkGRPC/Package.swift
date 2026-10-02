// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DonkGRPC",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "DonkGRPC", targets: ["DonkGRPC"]),
    ],
    dependencies: [
        .package(name: "Donk", path: "../.."),
        .package(url: "https://github.com/grpc/grpc-swift.git", "1.21.0"..<"2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.58.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.26.0"),
    ],
    targets: [
        .target(
            name: "DonkGRPC",
            dependencies: [
                .product(name: "DonkCore", package: "Donk"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
            ]
        ),
        .testTarget(
            name: "DonkGRPCTests",
            dependencies: [
                "DonkGRPC",
                .product(name: "DonkCore", package: "Donk"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
            ],
            exclude: ["Protos"]
        ),
    ]
)
