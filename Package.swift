// swift-tools-version:5.9

import PackageDescription
import CompilerPluginSupport
import Foundation

let includeNodeBridge = Context.environment["IMESSAGE_INCLUDE_NODE_BRIDGE"] == "1"

#if compiler(>=6.2)
let swiftCompilerSupportsChroma = true
#else
let swiftCompilerSupportsChroma = false
#endif

#if os(macOS)
let hostSupportsChroma = ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
)
#else
let hostSupportsChroma = false
#endif

let enableChromaHighlighting = swiftCompilerSupportsChroma && hostSupportsChroma

var products: [Product] = [
    .library(
        name: "PlatformSDK",
        targets: ["PlatformSDK"]
    ),
    .library(
        name: "IMessage",
        targets: ["IMessage"]
    ),
    .executable(name: "imessage-cli", targets: ["IMessageCLI"]),
    .executable(name: "IMDatabaseTestBench", targets: ["IMDatabaseTestBench"]),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sindresorhus/ExceptionCatcher", from: "2.0.1"),
    .package(url: "https://github.com/beeper/BetterSwiftAX.git", from: "0.1.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.1"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0-prerelease-2025-10-30"),
]

var iMessageCLIDependencies: [Target.Dependency] = [
    "IMessage",
    "IMessageCore",
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
    .product(name: "Yams", package: "Yams"),
]
var iMessageCLISwiftSettings: [SwiftSetting] = []
var platforms: [SupportedPlatform] = [.macOS(.v11)]

if enableChromaHighlighting {
    dependencies.append(.package(url: "https://github.com/onevcat/Chroma.git", from: "0.3.1"))
    iMessageCLIDependencies.append(.product(name: "Chroma", package: "Chroma"))
    iMessageCLISwiftSettings.append(.define("IMESSAGE_CLI_ENABLE_CHROMA"))
    platforms = [.macOS(.v13)]
}

var targets: [Target] = [
    .macro(
        name: "PlatformSDKMacros",
        dependencies: [
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        ],
        path: "src/IMessage/Sources/PlatformSDKMacros"
    ),
    .target(
        name: "PlatformSDK",
        dependencies: [
            "PlatformSDKMacros",
        ],
        path: "src/IMessage/Sources/PlatformSDK",
        exclude: ["readme.md"]
    ),
    .target(
        name: "IMessage",
        dependencies: [
            "BetterSwiftAX",
            "ExceptionCatcher",
            "IMessageCore",
            "IMessagePrivateSPI",
            "EmojiSPI",
            "IMDatabase",
            "PlatformSDK",
            .product(name: "Collections", package: "swift-collections"),
        ],
        path: "src/IMessage/Sources/IMessage"
    ),
    .target(
        name: "IMessagePrivateSPI",
        path: "src/IMessage/Sources/IMessagePrivateSPI",
        publicHeadersPath: "include"
    ),
    .target(
        name: "EmojiSPI",
        dependencies: ["IMessageCore"],
        path: "src/IMessage/Sources/EmojiSPI"
    ),
    .target(
        name: "SQLite",
        dependencies: [
            .product(name: "Logging", package: "swift-log"),
        ],
        path: "src/IMessage/Sources/SQLite"
    ),
    .testTarget(
        name: "SQLiteTests",
        dependencies: ["SQLite"],
        path: "src/IMessage/Sources/SQLiteTests"
    ),
    .target(
        name: "IMDatabase",
        dependencies: [
            .product(name: "Logging", package: "swift-log"),
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "Collections", package: "swift-collections"),
            "SQLite",
            "ExceptionCatcher",
            "IMessageCore",
        ],
        path: "src/IMessage/Sources/IMDatabase"
    ),
    .executableTarget(
        name: "IMessageCLI",
        dependencies: iMessageCLIDependencies,
        path: "src/IMessage/Sources/IMessageCLI",
        swiftSettings: iMessageCLISwiftSettings,
        plugins: ["GenerateIMessageCLIVersionPlugin"]
    ),
    .executableTarget(
        name: "IMDatabaseTestBench",
        dependencies: [
            "IMDatabase",
            "IMessageCore",
            "SQLite",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Logging", package: "swift-log"),
        ],
        path: "src/IMessage/Sources/IMDatabaseTestBench",
        exclude: ["README.md"]
    ),
    .plugin(
        name: "GenerateIMessageCLIVersionPlugin",
        capability: .buildTool(),
        dependencies: ["GenerateIMessageCLIVersion"],
        path: "src/IMessage/Plugins/GenerateIMessageCLIVersionPlugin"
    ),
    .executableTarget(
        name: "GenerateIMessageCLIVersion",
        path: "src/IMessage/Plugins/GenerateIMessageCLIVersion"
    ),
    .testTarget(
        name: "EmojiSPITests",
        dependencies: ["EmojiSPI"],
        path: "src/IMessage/Sources/EmojiSPITests"
    ),
    .testTarget(
        name: "IMessageTests",
        dependencies: ["IMessage", "IMessageCore", "IMDatabase", "PlatformSDK", "SQLite"],
        path: "src/IMessage/Sources/IMessageTests",
        resources: [.process("Fixtures")]
    ),
    .target(
        name: "CUnfairLock",
        dependencies: [],
        path: "src/IMessage/Sources/CUnfairLock"
    ),
    .target(
        name: "IMessageCore",
        dependencies: [
            .product(name: "Logging", package: "swift-log"),
            "ExceptionCatcher",
            "CUnfairLock",
        ],
        path: "src/IMessage/Sources/IMessageCore"
    ),
]

if includeNodeBridge {
    products.append(
        .library(
            name: "IMessageNode",
            type: .dynamic,
            targets: ["IMessageNode"]
        )
    )
    dependencies.append(.package(path: "node_modules/node-swift"))
    targets.append(
        .target(
            name: "IMessageNode",
            dependencies: [
                "IMessage",
                "IMessageCore",
                .product(name: "NodeAPI", package: "node-swift"),
                .product(name: "NodeModuleSupport", package: "node-swift"),
            ],
            path: "src/IMessage/Sources/IMessageNode",
            // `node-swift`'s build scripts pass some flags that enable dynamic
            // symbol resolution, which avoids N-API linkage errors at static
            // linking time. Replicate those here for SPM-backed debug builds.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])]
        )
    )
}

let package = Package(
    name: "IMessage",
    platforms: platforms,
    products: products,
    dependencies: dependencies,
    targets: targets
)
