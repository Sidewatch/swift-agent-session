// swift-tools-version: 6.0
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
        .target(name: "AgentSession", path: "Sources",
                swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        .testTarget(name: "AgentSessionTests", dependencies: ["AgentSession"], path: "Tests"),
    ]
)
