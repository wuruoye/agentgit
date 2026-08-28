import AgentGitCore
import AgentGitIntegrationShared
import Foundation
import XCTest
@testable import AgentGitApp

final class AgentPluginConfiguratorTests: XCTestCase {
    func testTimeoutErrorNamesProviderAndLimit() {
        let message = AgentPluginConfigurator.configurationErrorMessage(
            GitCommandTimeoutError(arguments: ["plugin", "list"]),
            provider: .claude
        )

        XCTAssertEqual(
            message,
            "Claude integration command did not finish within 15 seconds."
        )
    }

    func testAgentExecutableCandidatesUsePathAndCommonHomeLocations() {
        let homeURL = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let candidates = AgentPluginConfigurator.agentExecutableCandidates(
            provider: .codex,
            homeURL: homeURL,
            environment: ["PATH": "/custom/bin:/opt/homebrew/bin:/custom/bin"]
        )

        XCTAssertEqual(candidates.first?.path, "/custom/bin/codex")
        XCTAssertTrue(candidates.contains {
            $0.path == "/Users/example/.local/share/mise/shims/codex"
        })
        XCTAssertEqual(
            candidates.count(where: { $0.path == "/opt/homebrew/bin/codex" }),
            1
        )
    }

    func testAgentCommandPathStartsWithSelectedExecutableDirectory() {
        let environment = AgentPluginConfigurator.commandEnvironment(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            homeURL: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            environment: ["PATH": "/usr/bin:/custom/bin:/opt/homebrew/bin"]
        )
        let directories = environment["PATH"]?.split(separator: ":").map(String.init)

        XCTAssertEqual(directories?.first, "/opt/homebrew/bin")
        XCTAssertTrue(directories?.contains("/custom/bin") == true)
        XCTAssertTrue(
            directories?.contains("/Users/example/.local/share/mise/shims") == true
        )
        XCTAssertEqual(
            directories?.count(where: { $0 == "/opt/homebrew/bin" }),
            1
        )
    }

    func testOperationTrackerRejectsStaleResultsPerProvider() {
        var tracker = AgentPluginConfigurationOperationTracker()
        let firstCodex = tracker.begin(.codex)
        let claude = tracker.begin(.claude)
        let latestCodex = tracker.begin(.codex)

        XCTAssertFalse(tracker.accepts(firstCodex))
        XCTAssertTrue(tracker.accepts(latestCodex))
        XCTAssertTrue(tracker.accepts(claude))
        XCTAssertNotEqual(latestCodex.sequence, claude.sequence)
    }

    func testDecodesCodexPluginListDocument() throws {
        let output = Data(
            """
            {
              "installed": [
                {
                  "pluginId": "agentgit@personal",
                  "version": "0.1.0+codex.fixture",
                  "installed": true,
                  "enabled": true
                }
              ],
              "available": []
            }
            """.utf8
        )

        let plugins = try AgentPluginConfigurator.detectedPlugins(
            result: ExternalCommandResult(exitCode: 0, output: output, error: Data()),
            includesAvailable: false
        )

        XCTAssertEqual(
            plugins,
            [
                AgentInstalledPlugin(
                    pluginID: "agentgit@personal",
                    version: "0.1.0+codex.fixture",
                    installed: true,
                    enabled: true
                )
            ]
        )
    }

    func testDecodesClaudeInstalledPluginArray() throws {
        let output = Data(
            """
            [
              {
                "id": "agentgit@agentgit",
                "version": "0.1.0+codex.fixture",
                "scope": "user",
                "enabled": false,
                "installPath": "/Users/example/.claude/plugins/cache/agentgit/agentgit/version"
              }
            ]
            """.utf8
        )

        let plugins = try AgentPluginConfigurator.detectedPlugins(
            result: ExternalCommandResult(exitCode: 0, output: output, error: Data()),
            includesAvailable: false
        )

        XCTAssertEqual(plugins.first?.pluginID, "agentgit@agentgit")
        XCTAssertEqual(plugins.first?.version, "0.1.0+codex.fixture")
        XCTAssertEqual(plugins.first?.installed, true)
        XCTAssertEqual(plugins.first?.enabled, false)
    }

    func testPluginDescriptorDeclaresSkillAndSessionNavigation() {
        for provider in AgentProvider.allCases {
            let plugin = AgentIntegrationPlugin.plugin(for: provider)

            XCTAssertEqual(plugin.provider, provider)
            XCTAssertEqual(
                Set(plugin.capabilities),
                [.skill, .sessionNavigation]
            )
            XCTAssertTrue(plugin.manifestRelativePath.hasSuffix("plugin.json"))
        }
    }

    func testMarketplaceInstallerReadsBundledManifestVersions() throws {
        let rootURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/plugin-version-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let resourceURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
        let versions: [AgentProvider: String] = [
            .codex: "1.2.3+codex.current",
            .claude: "1.2.3+codex.current"
        ]
        for provider in AgentProvider.allCases {
            let plugin = AgentIntegrationPlugin.plugin(for: provider)
            let manifestURL = resourceURL
                .appendingPathComponent("AgentIntegrations", isDirectory: true)
                .appendingPathComponent(plugin.marketplaceResourceName, isDirectory: true)
                .appendingPathComponent(plugin.manifestRelativePath)
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: [
                "name": "agentgit",
                "version": try XCTUnwrap(versions[provider])
            ])
            try data.write(to: manifestURL)
        }
        let installer = AgentIntegrationMarketplaceInstaller(
            bundleResourceURL: resourceURL,
            applicationSupportURL: rootURL.appendingPathComponent(
                "Application Support/AgentGit",
                isDirectory: true
            )
        )

        for provider in AgentProvider.allCases {
            XCTAssertEqual(
                try installer.bundledVersion(.plugin(for: provider)),
                versions[provider]
            )
        }
    }

    func testMarketplaceInstallerReplacesStableApplicationSupportCopy() throws {
        let rootURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/plugin-marketplace-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let resourceURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
        let sourceURL = resourceURL
            .appendingPathComponent("AgentIntegrations", isDirectory: true)
            .appendingPathComponent("CodexMarketplace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        try Data("current".utf8).write(
            to: sourceURL.appendingPathComponent("version.txt")
        )
        let applicationSupportURL = rootURL.appendingPathComponent(
            "Application Support/AgentGit",
            isDirectory: true
        )
        let previousURL = applicationSupportURL
            .appendingPathComponent("AgentIntegrations", isDirectory: true)
            .appendingPathComponent("CodexMarketplace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: previousURL,
            withIntermediateDirectories: true
        )
        try Data("previous".utf8).write(
            to: previousURL.appendingPathComponent("stale.txt")
        )
        let installer = AgentIntegrationMarketplaceInstaller(
            bundleResourceURL: resourceURL,
            applicationSupportURL: applicationSupportURL
        )

        let installedURL = try installer.materialize(
            AgentIntegrationPlugin.plugin(for: .codex)
        )

        XCTAssertEqual(installedURL.standardizedFileURL, previousURL.standardizedFileURL)
        XCTAssertEqual(
            try String(
                contentsOf: installedURL.appendingPathComponent("version.txt"),
                encoding: .utf8
            ),
            "current"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installedURL.appendingPathComponent("stale.txt").path
            )
        )
    }
}
