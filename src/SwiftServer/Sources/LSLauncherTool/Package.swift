// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "LSLauncher",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(
            name: "LSLauncher",
            targets: ["LSLauncher"]
        ),
        .executable(
            name: "lslauncher-cli",
            targets: ["LSLauncherCLI"]
        ),
        .executable(
            name: "messages-deeplink-tester",
            targets: ["MessagesDeepLinkTester"]
        ),
    ],
    targets: [
        .target(
            name: "LSLauncher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices")
            ]
        ),
        .executableTarget(
            name: "LSLauncherCLI",
            dependencies: ["LSLauncher"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices")
            ]
        ),
        .executableTarget(
            name: "MessagesDeepLinkTester",
            dependencies: ["LSLauncher"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices")
            ]
        ),
    ]
)
