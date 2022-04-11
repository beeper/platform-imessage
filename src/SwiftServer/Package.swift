// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "SwiftServer",
    platforms: [.macOS(.v10_14)],
    products: [
        .library(
            name: "SwiftServer",
            targets: ["SwiftServer"]
        ),
    ],
    dependencies: [
        .package(path: "../../node_modules/node-swift"),
        .package(url: "https://github.com/TextsHQ/PHTCommon.git", .branch("main"))
    ],
    targets: [
        .target(
            name: "CWindowControl"
        ),
        .target(
            name: "WindowControl",
            dependencies: ["CWindowControl"]
        ),
        .target(
            name: "CAccessibilityControl"
        ),
        .target(
            name: "AccessibilityControl",
            dependencies: ["CAccessibilityControl", "WindowControl"]
        ),
        .target(
            name: "SwiftServer",
            dependencies: [
                "AccessibilityControl",
                "WindowControl",
                .product(name: "NodeAPI", package: "node-swift"),
                .product(name: "PHTClient", package: "PHTCommon")
            ]
        ),
    ]
)
