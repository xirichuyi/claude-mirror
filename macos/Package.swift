// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RemoteCC",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RemoteCC", targets: ["RemoteCC"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.9.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
    ],
    targets: [
        // Foundation only, so connection and protocol logic also build and test on Linux.
        .target(name: "RemoteCCCore"),
        .executableTarget(name: "RemoteCC", dependencies: ["RemoteCCCore", .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])), .product(name: "MarkdownUI", package: "swift-markdown-ui", condition: .when(platforms: [.macOS])), .product(name: "cmark-gfm", package: "swift-cmark", condition: .when(platforms: [.macOS])), .product(name: "cmark-gfm-extensions", package: "swift-cmark", condition: .when(platforms: [.macOS]))], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"], .when(platforms: [.macOS]))]),
        .testTarget(name: "RemoteCCCoreTests", dependencies: ["RemoteCCCore"]),
        .testTarget(name: "RemoteCCUITests", dependencies: ["RemoteCC"]),
    ]
)
