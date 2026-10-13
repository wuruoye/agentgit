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
        )
    ],
    swiftLanguageModes: [.v6]
)
