// swift-tools-version:5.8

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
        .executable(name: "IMDatabaseTestBench", targets: ["IMDatabaseTestBench"]),
    ],
    dependencies: [
        .package(path: "../../node_modules/node-swift"),
        .package(url: "https://github.com/sindresorhus/ExceptionCatcher", from: "2.0.1"),
        .package(url: "https://github.com/beeper/PHTCommon.git", revision: "cbbf93dfa5e084776f3ff0eaf9bb8dff9f2830bf"),
        .package(url: "https://github.com/TextsHQ/BetterSwiftAX", branch: "main"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.1"),
    ],
    targets: [
        .target(
            name: "SwiftServer",
            dependencies: [
                "BetterSwiftAX",
                "ExceptionCatcher",
                "SwiftServerFoundation",
                .product(name: "NodeAPI", package: "node-swift"),
                .product(name: "NodeModuleSupport", package: "node-swift"),
                .product(name: "PHTClient", package: "PHTCommon"),
                "EmojiSPI",
                "IMDatabase",
                .product(name: "Collections", package: "swift-collections"),
            ],

            // `node-swift`'s build scripts pass some flags that enable dynamic
            // symbol resolution, which avoids N-API linkage errors at static
            // linking time. replicate those here so we can build with SPM (just
            // to run tests).
            //
            // the actual build uses `xcodebuild`, so these settings in
            // particular get ignored
            linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])],
        ),
        .target(name: "EmojiSPI", dependencies: ["SwiftServerFoundation"]),
        .target(name: "SQLite", dependencies: [
            .product(name: "Logging", package: "swift-log"),
        ]),
        .testTarget(name: "SQLiteTests", dependencies: ["SQLite"]),
        .target(
            name: "IMDatabase",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Collections", package: "swift-collections"),
                "SQLite",
                "ExceptionCatcher",
                "SwiftServerFoundation",
            ],
        ),
        .executableTarget(
            name: "IMDatabaseTestBench",
            dependencies: [
                "IMDatabase",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "SwiftServerFoundation",
            ]
        ),
        .executableTarget(
            name: "AXTool",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "BetterSwiftAX",
                "SwiftServerFoundation",
            ]
        ),
        .testTarget(name: "EmojiSPITests", dependencies: ["EmojiSPI"]),
        .testTarget(name: "SwiftServerTests", dependencies: ["SwiftServer"]),
        .target(
            name: "CUnfairLock",
            dependencies: []
        ),
        .target(
            name: "SwiftServerFoundation",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "ExceptionCatcher",
                "CUnfairLock",
            ]
        ),
    ]
)
