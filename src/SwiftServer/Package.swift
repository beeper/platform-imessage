// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "SwiftServer",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(
            name: "SwiftServer",
            type: .dynamic,
            targets: ["SwiftServer"]
        ),
        // The dynamic target will cause linker errors in Xcode.
        // This target can be selected in Xcode for development.
        .library(
            name: "SwiftServer-Auto",
            targets: ["SwiftServer"]
        ),
    ],
    dependencies: [
        .package(path: "../../node_modules/node-swift"),
        .package(url: "https://github.com/sindresorhus/ExceptionCatcher", from: "2.0.1"),
        .package(url: "https://github.com/TextsHQ/PHTCommon.git", .revision("c37b857c81d9e49ebc827431d38432f07d4511fa")),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "CWindowControl"
        ),
        .target(
            name: "WindowControl",
            dependencies: ["CWindowControl", "SwiftServerFoundation"]
        ),
        .target(
            name: "CAccessibilityControl"
        ),
        .target(
            name: "AccessibilityControl",
            dependencies: ["CAccessibilityControl", "WindowControl", "SwiftServerFoundation"]
        ),
        .target(
            name: "SwiftServer",
            dependencies: [
                "AccessibilityControl",
                "WindowControl",
                "ExceptionCatcher",
                "SwiftServerFoundation",
                .product(name: "NodeAPI", package: "node-swift"),
                .product(name: "NodeModuleSupport", package: "node-swift"),
                .product(name: "PHTClient", package: "PHTCommon"),
                "CUnfairLock"
            ]
        ),
        .target(
            name: "CUnfairLock",
            dependencies: []
        ),
        .target(
            name: "SwiftServerFoundation",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        )
    ]
)
