// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TGSPlayerKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "TGSPlayerKit",
            targets: ["TGSPlayerKit"]
        )
    ],
    targets: [
        .target(name: "TGSPlayerKit"),
        .testTarget(
            name: "TGSPlayerKitTests",
            dependencies: ["TGSPlayerKit"]
        )
    ]
)
