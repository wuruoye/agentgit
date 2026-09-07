import AgentGitIntegrationShared
import Darwin
import Foundation

@main
private struct AgentGitSkillBridgeEntryPoint {
    static func main() {
        do {
            try run()
        } catch {
            // Hook failures never change the host tool result. Storage/decoding errors
            // inside the handler are recorded locally; even bootstrap failures fail open.
            if CommandLine.arguments.dropFirst().first == "hook" { return }
            writeError(error.localizedDescription)
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            throw AgentGitSkillBridgeError.invalidArguments
        }
        let options = try commandOptions(Array(arguments.dropFirst()))
        guard let providerValue = options["provider"],
              let provider = AgentProvider(rawValue: providerValue) else {
            throw AgentGitSkillBridgeError.invalidProvider
        }
        if command == "hook" {
            var data = Data()
            while data.count <= 2_000_000 {
                let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, 2_000_001 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            let version = pluginVersion(provider)
            let root: URL
            do {
                root = try dataDirectory()
            } catch {
                let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let fallback = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/AgentGit")
                if let feedback = AgentHookDiagnostic(rootURL: fallback, provider: provider, pluginVersion: version)
                    .feedback(event: event?["hook_event_name"] as? String, session: event?["session_id"] as? String,
                              message: error.localizedDescription) {
                    try writeJSON(feedback)
                }
                return
            }
            if let feedback = AgentHookRegistration(
                rootURL: root, provider: provider, pluginVersion: version
            ).handle(data) {
                try writeJSON(feedback)
            }
            return
        }
        guard let sessionID = options["session"],
              let worktreePath = options["worktree"] else {
            throw AgentGitSkillBridgeError.invalidArguments
        }
        let service = try registrationService()
        let candidateURL = URL(
            fileURLWithPath: worktreePath,
            isDirectory: true
        )
        switch command {
        case "status":
            try writeJSON(
                service.status(
                    provider: provider,
                    sessionID: sessionID,
                    candidateURL: candidateURL
                )
            )
        case "register":
            try writeJSON(
                service.register(
                    provider: provider,
                    sessionID: sessionID,
                    candidateURL: candidateURL,
                    title: options["title"] ?? "",
                    summary: options["summary"] ?? ""
                )
            )
        default:
            throw AgentGitSkillBridgeError.invalidArguments
        }
    }

    private static func commandOptions(
        _ arguments: [String]
    ) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw AgentGitSkillBridgeError.invalidArguments
        }
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), name.count > 2 else {
                throw AgentGitSkillBridgeError.invalidArguments
            }
            options[String(name.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        return options
    }

    private static func pluginVersion(_ provider: AgentProvider) -> String? {
        let pluginRoot = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = pluginRoot.appendingPathComponent(
            provider == .codex ? ".codex-plugin/plugin.json" : ".claude-plugin/plugin.json"
        )
        guard let data = try? Data(contentsOf: manifest), data.count <= 64_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }

    private static func registrationService() throws -> AgentSkillRegistrationService {
        let rootURL = try dataDirectory()
        return AgentSkillRegistrationService(
            associationStore: AgentAssociationStore(
                storeURL: rootURL.appendingPathComponent("associations.json")
            ),
            auditStore: AgentRegistrationAuditStore(
                storeURL: rootURL.appendingPathComponent("registration-events.json")
            )
        )
    }

    private static func dataDirectory() throws -> URL {
        let rootURL: URL
        if let configuredPath = ProcessInfo.processInfo.environment[
            "AGENTGIT_DATA_DIRECTORY"
        ] {
            guard configuredPath.hasPrefix("/") else {
                throw AgentGitSkillBridgeError.invalidDataDirectory
            }
            rootURL = URL(
                fileURLWithPath: configuredPath,
                isDirectory: true
            ).standardizedFileURL
        } else {
            let applicationSupportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            rootURL = applicationSupportURL.appendingPathComponent(
                "AgentGit",
                isDirectory: true
            )
        }
        return rootURL
    }

    private static func writeJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func writeError(_ message: String) {
        try? FileHandle.standardError.write(
            contentsOf: Data("AgentGit: \(message)\n".utf8)
        )
    }
}

private enum AgentGitSkillBridgeError: LocalizedError {
    case invalidArguments
    case invalidProvider
    case invalidDataDirectory

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: AgentGitSkillBridge status --provider <codex|claude> "
                + "--session <id> --worktree <path>, or register with "
                + "--title <title> --summary <summary>."
        case .invalidProvider:
            "Provider must be codex or claude."
        case .invalidDataDirectory:
            "AGENTGIT_DATA_DIRECTORY must be an absolute path."
        }
    }
}
