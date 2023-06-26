// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "SwiftServer",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(
            name: "SwiftServer",
            targets: ["SwiftServer"]
        ),
    ],
    dependencies: [
        .package(path: "../../node_modules/node-swift"),
        .package(url: "https://github.com/sindresorhus/ExceptionCatcher", from: "2.0.1"),
        .package(url: "https://github.com/TextsHQ/PHTCommon.git", .revision("c37b857c81d9e49ebc827431d38432f07d4511fa"))
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
                "ExceptionCatcher",
                .product(name: "NodeAPI", package: "node-swift"),
                .product(name: "PHTClient", package: "PHTCommon"),
                "CUnfairLock"
            ]
        ),
        .target(
            name: "CUnfairLock",
            dependencies: []
        )
    ]
)
