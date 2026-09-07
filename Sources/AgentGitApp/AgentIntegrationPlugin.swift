import AgentGitIntegrationShared
import Foundation

enum AgentIntegrationCapability: String, CaseIterable, Hashable, Sendable {
    case skill = "Manual Registration"
    case automaticRegistration = "Automatic Registration"
    case sessionNavigation = "Session Jump"
}

struct AgentIntegrationPlugin: Identifiable, Hashable, Sendable {
    let provider: AgentProvider
    let marketplaceResourceName: String
    let marketplaceName: String
    let manifestRelativePath: String
    let capabilities: [AgentIntegrationCapability]

    var id: AgentProvider {
        provider
    }

    var pluginID: String {
        "agentgit@\(marketplaceName)"
    }

    static func plugin(for provider: AgentProvider) -> AgentIntegrationPlugin {
        switch provider {
        case .codex:
            AgentIntegrationPlugin(
                provider: provider,
                marketplaceResourceName: "CodexMarketplace",
                marketplaceName: "personal",
                manifestRelativePath: "plugins/agentgit/.codex-plugin/plugin.json",
                capabilities: [.automaticRegistration, .skill, .sessionNavigation]
            )
        case .claude:
            AgentIntegrationPlugin(
                provider: provider,
                marketplaceResourceName: "ClaudeMarketplace",
                marketplaceName: "agentgit",
                manifestRelativePath: "plugins/agentgit/.claude-plugin/plugin.json",
                capabilities: [.automaticRegistration, .skill, .sessionNavigation]
            )
        }
    }
}

struct AgentInstalledPlugin: Equatable, Sendable {
    let pluginID: String
    let version: String?
    let installed: Bool
    let enabled: Bool
}

struct AgentPluginListDocument: Decodable {
    struct Entry: Decodable {
        let pluginID: String
        let version: String?
        let enabled: Bool?
        let installed: Bool?

        private enum CodingKeys: String, CodingKey {
            case pluginID = "pluginId"
            case id
            case version
            case enabled
            case installed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let pluginID = try container.decodeIfPresent(
                String.self,
                forKey: .pluginID
            ) {
                self.pluginID = pluginID
            } else {
                self.pluginID = try container.decode(String.self, forKey: .id)
            }
            version = try container.decodeIfPresent(String.self, forKey: .version)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            installed = try container.decodeIfPresent(Bool.self, forKey: .installed)
        }
    }

    let installed: [Entry]
    let available: [Entry]?

    private enum CodingKeys: String, CodingKey {
        case installed
        case available
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let entries = try? singleValue.decode([Entry].self) {
            installed = entries
            available = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        installed = try container.decode([Entry].self, forKey: .installed)
        available = try container.decodeIfPresent([Entry].self, forKey: .available)
    }
}

enum AgentIntegrationMarketplaceError: LocalizedError {
    case bundledMarketplaceMissing(String)
    case bundledManifestMissing(String)
    case bundledManifestInvalid(String)

    var errorDescription: String? {
        switch self {
        case let .bundledMarketplaceMissing(name):
            "The bundled \(name) integration marketplace is missing."
        case let .bundledManifestMissing(name):
            "The bundled \(name) integration manifest is missing."
        case let .bundledManifestInvalid(name):
            "The bundled \(name) integration manifest is invalid."
        }
    }
}

struct AgentIntegrationMarketplaceInstaller: Sendable {
    let bundleResourceURL: URL
    let applicationSupportURL: URL

    init(
        bundleResourceURL: URL,
        applicationSupportURL: URL
    ) {
        self.bundleResourceURL = bundleResourceURL.standardizedFileURL
        self.applicationSupportURL = applicationSupportURL.standardizedFileURL
    }

    func materialize(_ plugin: AgentIntegrationPlugin) throws -> URL {
        let sourceURL = try marketplaceSourceURL(plugin)
        let integrationsURL = applicationSupportURL.appendingPathComponent(
            "AgentIntegrations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: integrationsURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destinationURL = integrationsURL.appendingPathComponent(
            plugin.marketplaceResourceName,
            isDirectory: true
        )
        let stagingURL = integrationsURL.appendingPathComponent(
            ".\(plugin.marketplaceResourceName).\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(
                at: stagingURL,
                to: destinationURL
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: destinationURL.path
            )
            return destinationURL
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    func bundledVersion(_ plugin: AgentIntegrationPlugin) throws -> String {
        let manifestURL = try marketplaceSourceURL(plugin)
            .appendingPathComponent(plugin.manifestRelativePath)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw AgentIntegrationMarketplaceError.bundledManifestMissing(
                plugin.provider.displayName
            )
        }
        guard let document = try? JSONDecoder().decode(
            AgentIntegrationPluginManifest.self,
            from: Data(contentsOf: manifestURL)
        ), !document.version.isEmpty else {
            throw AgentIntegrationMarketplaceError.bundledManifestInvalid(
                plugin.provider.displayName
            )
        }
        return document.version
    }

    private func marketplaceSourceURL(
        _ plugin: AgentIntegrationPlugin
    ) throws -> URL {
        let sourceURL = bundleResourceURL
            .appendingPathComponent("AgentIntegrations", isDirectory: true)
            .appendingPathComponent(
                plugin.marketplaceResourceName,
                isDirectory: true
            )
        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: sourceURL.path,
            isDirectory: &sourceIsDirectory
        ), sourceIsDirectory.boolValue else {
            throw AgentIntegrationMarketplaceError.bundledMarketplaceMissing(
                plugin.provider.displayName
            )
        }
        return sourceURL
    }
}

private struct AgentIntegrationPluginManifest: Decodable {
    let version: String
}
