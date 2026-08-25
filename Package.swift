// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentGit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentGitCore", targets: ["AgentGitCore"]),
        .executable(name: "AgentGitApp", targets: ["AgentGitApp"])
    ],
    targets: [
        .target(name: "AgentGitCore"),
        .executableTarget(
            name: "AgentGitApp",
            dependencies: ["AgentGitCore"]
        ),
        .testTarget(
            name: "AgentGitCoreTests",
            dependencies: ["AgentGitCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
