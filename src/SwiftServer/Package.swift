// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "SwiftServer",
    platforms: [.macOS(.v10_11)],
    products: [
        .library(
            name: "SwiftServer",
            targets: ["SwiftServer"]
        ),
    ],
    dependencies: [
        .package(path: "../../node_modules/node-swift")
    ],
    targets: [
        .target(
            name: "AccessibilityControl"
        ),
        .target(
            name: "SwiftServer",
            dependencies: [
                "AccessibilityControl",
                .product(name: "NodeAPI", package: "node-swift")
            ]
        ),
    ]
)
