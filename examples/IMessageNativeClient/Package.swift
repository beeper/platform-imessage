// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "IMessageNativeClientExample",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "imessage-native-client", targets: ["IMessageNativeClient"]),
    ],
    dependencies: [
        .package(name: "IMessage", path: "../.."),
        .package(url: "https://github.com/mchakravarty/CodeEditorView.git", from: "0.15.4"),
    ],
    targets: [
        .executableTarget(
            name: "IMessageNativeClient",
            dependencies: [
                .product(name: "IMessage", package: "IMessage"),
                .product(name: "PlatformSDK", package: "IMessage"),
                .product(name: "CodeEditorView", package: "CodeEditorView"),
                .product(name: "LanguageSupport", package: "CodeEditorView"),
            ],
            path: "Sources/IMessageNativeClient"
        ),
    ]
)
