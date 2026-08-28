import AgentGitCore
import AgentGitIntegrationShared
import Foundation
import Observation

enum AgentPluginConfigurationStatus: Equatable {
    case notChecked
    case notConfigured
    case needsUpdate
    case configuring
    case disabling
    case configured
    case failed(String)

    var title: String {
        switch self {
        case .notChecked: "Checking…"
        case .notConfigured: "Disabled"
        case .needsUpdate: "Update Available"
        case .configuring: "Enabling…"
        case .disabling: "Disabling…"
        case .configured: "Enabled"
        case .failed: "Integration Failed"
        }
    }
}

struct AgentPluginConfigurationOperation: Equatable, Sendable {
    let provider: AgentProvider
    let sequence: UInt64
}

struct AgentPluginConfigurationOperationTracker: Sendable {
    private var nextSequence: UInt64 = 0
    private var latestSequenceByProvider: [AgentProvider: UInt64] = [:]

    mutating func begin(
        _ provider: AgentProvider
    ) -> AgentPluginConfigurationOperation {
        nextSequence &+= 1
        latestSequenceByProvider[provider] = nextSequence
        return AgentPluginConfigurationOperation(
            provider: provider,
            sequence: nextSequence
        )
    }

    func accepts(_ operation: AgentPluginConfigurationOperation) -> Bool {
        latestSequenceByProvider[operation.provider] == operation.sequence
    }
}

@MainActor
@Observable
final class AgentPluginConfigurator {
    private(set) var statusByProvider: [AgentProvider: AgentPluginConfigurationStatus] = [
        .codex: .notChecked,
        .claude: .notChecked
    ]
    private var operationTracker = AgentPluginConfigurationOperationTracker()
    private let marketplaceInstaller: AgentIntegrationMarketplaceInstaller

    init(
        marketplaceInstaller: AgentIntegrationMarketplaceInstaller? = nil
    ) {
        if let marketplaceInstaller {
            self.marketplaceInstaller = marketplaceInstaller
            return
        }
        let resourceURL = Bundle.main.resourceURL
            ?? Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Resources",
                isDirectory: true
            )
        let applicationSupportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.marketplaceInstaller = AgentIntegrationMarketplaceInstaller(
            bundleResourceURL: resourceURL,
            applicationSupportURL: applicationSupportRoot.appendingPathComponent(
                "AgentGit",
                isDirectory: true
            )
        )
    }

    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in AgentProvider.allCases {
                group.addTask { [weak self] in
                    await self?.refresh(provider)
                }
            }
        }
    }

    func enable(_ provider: AgentProvider) async {
        guard statusByProvider[provider] != .configuring,
              statusByProvider[provider] != .disabling else {
            return
        }
        let operation = operationTracker.begin(provider)
        statusByProvider[provider] = .configuring
        do {
            let plugin = AgentIntegrationPlugin.plugin(for: provider)
            let bundledVersion = try marketplaceInstaller.bundledVersion(plugin)
            let executableURL = try Self.agentExecutableURL(provider)
            let marketplaceURL = try marketplaceInstaller.materialize(plugin)
            let availableBefore = try await Self.pluginList(
                executableURL: executableURL,
                includesAvailable: true
            )
            if !availableBefore.contains(where: {
                $0.pluginID == plugin.pluginID
            }) {
                try await Self.requireSuccessfulCommand(
                    executableURL: executableURL,
                    arguments: Self.marketplaceAddArguments(
                        provider: provider,
                        marketplaceURL: marketplaceURL
                    )
                )
            } else if let arguments = Self.marketplaceUpdateArguments(
                provider: provider,
                plugin: plugin
            ) {
                try await Self.requireSuccessfulCommand(
                    executableURL: executableURL,
                    arguments: arguments
                )
            }
            let current = try await Self.pluginList(
                executableURL: executableURL,
                includesAvailable: true
            ).first(where: {
                $0.pluginID == plugin.pluginID && $0.installed
            })
            if let current {
                try await Self.prepareInstalledPlugin(
                    current,
                    provider: provider,
                    plugin: plugin,
                    bundledVersion: bundledVersion,
                    executableURL: executableURL
                )
            } else {
                try await Self.requireSuccessfulCommand(
                    executableURL: executableURL,
                    arguments: Self.pluginInstallArguments(
                        provider: provider,
                        plugin: plugin
                    )
                )
            }
            let installed = try await Self.pluginList(
                executableURL: executableURL,
                includesAvailable: false
            )
            guard installed.contains(where: {
                $0.pluginID == plugin.pluginID
                    && $0.enabled
                    && $0.version == bundledVersion
            }) else {
                throw AgentPluginConfigurationError.verificationFailed
            }
            updateStatus(.configured, for: operation)
        } catch is CancellationError {
            updateStatus(.notChecked, for: operation)
        } catch {
            updateStatus(
                .failed(Self.configurationErrorMessage(error, provider: provider)),
                for: operation
            )
        }
    }

    func disable(_ provider: AgentProvider) async {
        guard statusByProvider[provider] != .configuring,
              statusByProvider[provider] != .disabling else {
            return
        }
        let operation = operationTracker.begin(provider)
        statusByProvider[provider] = .disabling
        do {
            let plugin = AgentIntegrationPlugin.plugin(for: provider)
            let executableURL = try Self.agentExecutableURL(provider)
            let installed = try await Self.pluginList(
                executableURL: executableURL,
                includesAvailable: false
            )
            if installed.contains(where: {
                $0.pluginID == plugin.pluginID && $0.enabled
            }) {
                try await Self.requireSuccessfulCommand(
                    executableURL: executableURL,
                    arguments: Self.pluginDisableArguments(
                        provider: provider,
                        plugin: plugin
                    )
                )
            }
            let verified = try await Self.pluginList(
                executableURL: executableURL,
                includesAvailable: false
            )
            guard !verified.contains(where: {
                $0.pluginID == plugin.pluginID && $0.enabled
            }) else {
                throw AgentPluginConfigurationError.verificationFailed
            }
            updateStatus(.notConfigured, for: operation)
        } catch is CancellationError {
            updateStatus(.notChecked, for: operation)
        } catch {
            updateStatus(
                .failed(Self.configurationErrorMessage(error, provider: provider)),
                for: operation
            )
        }
    }

    private func refresh(_ provider: AgentProvider) async {
        guard statusByProvider[provider] != .configuring,
              statusByProvider[provider] != .disabling else {
            return
        }
        let operation = operationTracker.begin(provider)
        do {
            let executableURL = try Self.agentExecutableURL(provider)
            let plugin = AgentIntegrationPlugin.plugin(for: provider)
            let bundledVersion = try marketplaceInstaller.bundledVersion(plugin)
            let installed = try await Self.pluginList(
                executableURL: executableURL,
                includesAvailable: false
            )
            if let detected = installed.first(where: {
                $0.pluginID == plugin.pluginID
            }) {
                if detected.version != bundledVersion {
                    updateStatus(.needsUpdate, for: operation)
                } else {
                    updateStatus(
                        detected.enabled ? .configured : .notConfigured,
                        for: operation
                    )
                }
            } else {
                updateStatus(.notConfigured, for: operation)
            }
        } catch is CancellationError {
            updateStatus(.notChecked, for: operation)
        } catch {
            updateStatus(
                .failed(Self.configurationErrorMessage(error, provider: provider)),
                for: operation
            )
        }
    }

    private func updateStatus(
        _ status: AgentPluginConfigurationStatus,
        for operation: AgentPluginConfigurationOperation
    ) {
        guard operationTracker.accepts(operation) else {
            return
        }
        statusByProvider[operation.provider] = status
    }

    nonisolated static func configurationErrorMessage(
        _ error: any Error,
        provider: AgentProvider
    ) -> String {
        if error is GitCommandTimeoutError {
            return "\(provider.displayName) integration command did not finish within 15 seconds."
        }
        return error.localizedDescription
    }

    private static func pluginListArguments(
        includesAvailable: Bool
    ) -> [String] {
        var arguments = ["plugin", "list"]
        if includesAvailable {
            arguments.append("--available")
        }
        arguments.append("--json")
        return arguments
    }

    private static func marketplaceAddArguments(
        provider: AgentProvider,
        marketplaceURL: URL
    ) -> [String] {
        switch provider {
        case .codex:
            ["plugin", "marketplace", "add", marketplaceURL.path, "--json"]
        case .claude:
            ["plugin", "marketplace", "add", "--scope", "user", marketplaceURL.path]
        }
    }

    private static func marketplaceUpdateArguments(
        provider: AgentProvider,
        plugin: AgentIntegrationPlugin
    ) -> [String]? {
        switch provider {
        case .codex:
            nil
        case .claude:
            ["plugin", "marketplace", "update", plugin.marketplaceName]
        }
    }

    private static func pluginInstallArguments(
        provider: AgentProvider,
        plugin: AgentIntegrationPlugin
    ) -> [String] {
        switch provider {
        case .codex:
            ["plugin", "add", plugin.pluginID, "--json"]
        case .claude:
            ["plugin", "install", "--scope", "user", "--yes", plugin.pluginID]
        }
    }

    private static func pluginRemoveArguments(
        provider: AgentProvider,
        plugin: AgentIntegrationPlugin
    ) -> [String] {
        switch provider {
        case .codex:
            ["plugin", "remove", plugin.pluginID, "--json"]
        case .claude:
            ["plugin", "uninstall", "--scope", "user", "--yes", plugin.pluginID]
        }
    }

    private static func pluginDisableArguments(
        provider: AgentProvider,
        plugin: AgentIntegrationPlugin
    ) -> [String] {
        switch provider {
        case .codex:
            pluginRemoveArguments(provider: provider, plugin: plugin)
        case .claude:
            ["plugin", "disable", "--scope", "user", plugin.pluginID]
        }
    }

    private static func pluginEnableArguments(
        provider: AgentProvider,
        plugin: AgentIntegrationPlugin
    ) -> [String]? {
        switch provider {
        case .codex:
            nil
        case .claude:
            ["plugin", "enable", "--scope", "user", plugin.pluginID]
        }
    }

    private static func pluginUpdateArguments(
        provider: AgentProvider,
        plugin: AgentIntegrationPlugin
    ) -> [String]? {
        switch provider {
        case .codex:
            nil
        case .claude:
            ["plugin", "update", "--scope", "user", "--yes", plugin.pluginID]
        }
    }

    private static func prepareInstalledPlugin(
        _ installed: AgentInstalledPlugin,
        provider: AgentProvider,
        plugin: AgentIntegrationPlugin,
        bundledVersion: String,
        executableURL: URL
    ) async throws {
        if installed.version != bundledVersion {
            if let arguments = pluginUpdateArguments(
                provider: provider,
                plugin: plugin
            ) {
                try await requireSuccessfulCommand(
                    executableURL: executableURL,
                    arguments: arguments
                )
            } else {
                try await requireSuccessfulCommand(
                    executableURL: executableURL,
                    arguments: pluginRemoveArguments(
                        provider: provider,
                        plugin: plugin
                    )
                )
                try await requireSuccessfulCommand(
                    executableURL: executableURL,
                    arguments: pluginInstallArguments(
                        provider: provider,
                        plugin: plugin
                    )
                )
            }
        }
        guard !installed.enabled,
              let arguments = pluginEnableArguments(
                provider: provider,
                plugin: plugin
              ) else {
            return
        }
        try await requireSuccessfulCommand(
            executableURL: executableURL,
            arguments: arguments
        )
    }

    private static func pluginList(
        executableURL: URL,
        includesAvailable: Bool
    ) async throws -> [AgentInstalledPlugin] {
        let result = try await run(
            executableURL: executableURL,
            arguments: pluginListArguments(
                includesAvailable: includesAvailable
            )
        )
        guard result.exitCode == 0 else {
            throw AgentPluginConfigurationError.commandFailed(result.errorText)
        }
        return try detectedPlugins(
            result: result,
            includesAvailable: includesAvailable
        )
    }

    nonisolated static func detectedPlugins(
        result: ExternalCommandResult,
        includesAvailable: Bool
    ) throws -> [AgentInstalledPlugin] {
        guard result.exitCode == 0 else {
            return []
        }
        let document = try JSONDecoder().decode(
            AgentPluginListDocument.self,
            from: result.output
        )
        var plugins = document.installed.map { entry in
            AgentInstalledPlugin(
                pluginID: entry.pluginID,
                version: entry.version,
                installed: entry.installed ?? true,
                enabled: entry.enabled ?? true
            )
        }
        if includesAvailable {
            let installedIDs = Set(plugins.map(\.pluginID))
            plugins.append(contentsOf: (document.available ?? []).compactMap { entry in
                guard !installedIDs.contains(entry.pluginID) else {
                    return nil
                }
                return AgentInstalledPlugin(
                    pluginID: entry.pluginID,
                    version: entry.version,
                    installed: entry.installed ?? false,
                    enabled: entry.enabled ?? false
                )
            })
        }
        return plugins
    }

    private static func requireSuccessfulCommand(
        executableURL: URL,
        arguments: [String]
    ) async throws {
        let result = try await run(
            executableURL: executableURL,
            arguments: arguments
        )
        guard result.exitCode == 0 else {
            throw AgentPluginConfigurationError.commandFailed(result.errorText)
        }
    }

    private static func agentExecutableURL(_ provider: AgentProvider) throws -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let candidates = agentExecutableCandidates(
            provider: provider,
            homeURL: homeURL,
            environment: ProcessInfo.processInfo.environment
        )
        guard let executableURL = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw AgentPluginConfigurationError.agentExecutableMissing(provider)
        }
        return executableURL
    }

    nonisolated static func agentExecutableCandidates(
        provider: AgentProvider,
        homeURL: URL,
        environment: [String: String]
    ) -> [URL] {
        agentExecutableDirectories(
            homeURL: homeURL,
            environment: environment
        ).map {
            $0.appendingPathComponent(provider.rawValue).standardizedFileURL
        }
    }

    nonisolated static func commandEnvironment(
        executableURL: URL,
        homeURL: URL,
        environment: [String: String]
    ) -> [String: String] {
        let executableDirectory = executableURL.standardizedFileURL
            .deletingLastPathComponent()
        let directories = [executableDirectory] + agentExecutableDirectories(
            homeURL: homeURL,
            environment: environment
        )
        var seenPaths: Set<String> = []
        let path = directories.compactMap { directory -> String? in
            let standardizedPath = directory.standardizedFileURL.path
            return seenPaths.insert(standardizedPath).inserted
                ? standardizedPath
                : nil
        }.joined(separator: ":")
        return ["PATH": path]
    }

    private nonisolated static func agentExecutableDirectories(
        homeURL: URL,
        environment: [String: String]
    ) -> [URL] {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let standardDirectories = [
            homeURL.appendingPathComponent(".local/bin", isDirectory: true),
            homeURL.appendingPathComponent("bin", isDirectory: true),
            homeURL.appendingPathComponent(".nix-profile/bin", isDirectory: true),
            homeURL.appendingPathComponent(".local/share/mise/shims", isDirectory: true),
            homeURL.appendingPathComponent(".asdf/shims", isDirectory: true),
            homeURL.appendingPathComponent(".volta/bin", isDirectory: true),
            homeURL.appendingPathComponent("Library/pnpm", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/sbin", isDirectory: true),
            URL(fileURLWithPath: "/sbin", isDirectory: true)
        ]
        var seenPaths: Set<String> = []
        return (pathDirectories + standardDirectories).compactMap { directory in
            let standardized = directory.standardizedFileURL
            return seenPaths.insert(standardized.path).inserted ? standardized : nil
        }
    }

    private static func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> ExternalCommandResult {
        let runner = GitCommandRunner(executableURL: executableURL)
        let environment = ProcessInfo.processInfo.environment
        do {
            let output = try await runner.run(
                arguments: arguments,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                maximumOutputBytes: 1 * 1_024 * 1_024,
                environment: commandEnvironment(
                    executableURL: executableURL,
                    homeURL: FileManager.default.homeDirectoryForCurrentUser,
                    environment: environment
                ),
                timeout: .seconds(15)
            )
            return ExternalCommandResult(
                exitCode: 0,
                output: output,
                error: Data()
            )
        } catch let failure as GitCommandFailure {
            return ExternalCommandResult(
                exitCode: failure.exitCode,
                output: Data(),
                error: Data(failure.stderr.utf8)
            )
        }
    }
}

struct ExternalCommandResult: Sendable {
    let exitCode: Int32
    let output: Data
    let error: Data

    var errorText: String {
        let text = String(decoding: error, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Agent integration command failed." : text
    }
}

private enum AgentPluginConfigurationError: LocalizedError {
    case agentExecutableMissing(AgentProvider)
    case commandFailed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case let .agentExecutableMissing(provider):
            "\(provider.displayName) CLI was not found."
        case let .commandFailed(message):
            message
        case .verificationFailed:
            "The agent CLI did not return an enabled AgentGit integration plugin."
        }
    }
}
