// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentGit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentGitCore", targets: ["AgentGitCore"]),
        .library(name: "AgentGitIntegrationShared", targets: ["AgentGitIntegrationShared"]),
        .executable(name: "AgentGitApp", targets: ["AgentGitApp"])
    ],
    targets: [
        .target(name: "AgentGitCore"),
        .target(name: "AgentGitIntegrationShared"),
        .executableTarget(
            name: "AgentGitApp",
            dependencies: ["AgentGitCore", "AgentGitIntegrationShared"],
            resources: [.copy("Resources/ReviewIcons")]
        ),
        .testTarget(
            name: "AgentGitCoreTests",
            dependencies: ["AgentGitCore"]
        ),
        .testTarget(
            name: "AgentGitAppTests",
            dependencies: ["AgentGitApp", "AgentGitCore", "AgentGitIntegrationShared"]
        ),
        .testTarget(
            name: "AgentGitIntegrationSharedTests",
            dependencies: ["AgentGitIntegrationShared"]
        )
    ],
    swiftLanguageModes: [.v6]
)
