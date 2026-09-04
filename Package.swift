// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentSession",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentSession", targets: ["AgentSession"]),
    ],
    targets: [
        .target(name: "AgentSession", path: "Sources",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AgentSessionTests", dependencies: ["AgentSession"], path: "Tests"),
    ]
)
