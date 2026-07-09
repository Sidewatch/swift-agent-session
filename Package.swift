// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentSession",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "AgentSession", targets: ["AgentSession"]),
    ],
    targets: [
        .target(name: "AgentSession", path: "Sources"),
        .testTarget(name: "AgentSessionTests", dependencies: ["AgentSession"], path: "Tests"),
    ]
)
