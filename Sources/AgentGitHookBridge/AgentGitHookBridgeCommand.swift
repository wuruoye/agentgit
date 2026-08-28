import AgentGitIntegrationShared
import Darwin
import Foundation

@main
private struct AgentGitHookBridgeEntryPoint {
    static func main() {
        do {
            try run()
        } catch {
            writeError(error.localizedDescription)
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            throw AgentGitHookBridgeError.invalidArguments
        }
        let options = try commandOptions(Array(arguments.dropFirst()))
        let stores = try stores()
        switch command {
        case "guard":
            guard let providerValue = options["provider"],
                  let provider = AgentProvider(rawValue: providerValue) else {
                throw AgentGitHookBridgeError.invalidProvider
            }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard input.count <= 1_048_576 else {
                throw AgentGitHookBridgeError.hookInputTooLarge
            }
            let event = try JSONDecoder().decode(AgentHookEvent.self, from: input)
            let inheritedSessionID = switch provider {
            case .codex:
                ProcessInfo.processInfo.environment["CODEX_THREAD_ID"]
            case .claude:
                ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"]
            }
            let guardService = AgentWriteRegistrationGuard(
                associationStore: stores.associations,
                intentStore: stores.intents,
                responseStore: stores.responses,
                auditStore: stores.audit
            )
            switch guardService.evaluate(
                provider: provider,
                event: event,
                inheritedSessionID: inheritedSessionID
            ) {
            case .allow:
                return
            case let .registrationRequired(intent):
                writeError(
                    "AgentGit registration is required for \(intent.worktreePath). "
                        + "Invoke the agentgit-register skill with token "
                        + "\(intent.id.uuidString.lowercased()), then retry this tool call."
                )
                Darwin.exit(2)
            case let .blocked(message):
                writeError(message)
                Darwin.exit(2)
            }
        case "inspect":
            guard let token = options["token"] else {
                throw AgentGitHookBridgeError.invalidArguments
            }
            try writeJSON(stores.intents.load(token: token))
        case "register":
            guard let token = options["token"],
                  let title = options["title"] else {
                throw AgentGitHookBridgeError.invalidArguments
            }
            let service = AgentWriteRegistrationHandoffService(
                intentStore: stores.intents,
                responseStore: stores.responses
            )
            let response = try service.prepare(
                token: token,
                title: title,
                summary: options["summary"] ?? ""
            )
            try writeJSON(response)
        default:
            throw AgentGitHookBridgeError.invalidArguments
        }
    }

    private static func commandOptions(
        _ arguments: [String]
    ) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw AgentGitHookBridgeError.invalidArguments
        }
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), name.count > 2 else {
                throw AgentGitHookBridgeError.invalidArguments
            }
            options[String(name.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        return options
    }

    private static func stores() throws -> AgentGitHookBridgeStores {
        let rootURL: URL
        if let configuredPath = ProcessInfo.processInfo.environment[
            "AGENTGIT_DATA_DIRECTORY"
        ] {
            guard configuredPath.hasPrefix("/") else {
                throw AgentGitHookBridgeError.invalidDataDirectory
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
        let responseDirectory: URL
        if let configuredPath = ProcessInfo.processInfo.environment[
            "AGENTGIT_HANDOFF_DIRECTORY"
        ] {
            guard configuredPath.hasPrefix("/") else {
                throw AgentGitHookBridgeError.invalidHandoffDirectory
            }
            responseDirectory = URL(
                fileURLWithPath: configuredPath,
                isDirectory: true
            ).standardizedFileURL
        } else {
            responseDirectory = AgentWriteRegistrationResponseStore
                .defaultDirectoryURL()
        }
        return AgentGitHookBridgeStores(
            associations: AgentAssociationStore(
                storeURL: rootURL.appendingPathComponent("associations.json")
            ),
            intents: AgentWriteIntentStore(
                directoryURL: rootURL.appendingPathComponent(
                    "pending-write-intents",
                    isDirectory: true
                )
            ),
            responses: AgentWriteRegistrationResponseStore(
                directoryURL: responseDirectory
            ),
            audit: AgentRegistrationAuditStore(
                storeURL: rootURL.appendingPathComponent(
                    "registration-events.json"
                )
            )
        )
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

private struct AgentGitHookBridgeStores {
    let associations: AgentAssociationStore
    let intents: AgentWriteIntentStore
    let responses: AgentWriteRegistrationResponseStore
    let audit: AgentRegistrationAuditStore
}

private enum AgentGitHookBridgeError: LocalizedError {
    case invalidArguments
    case invalidProvider
    case invalidDataDirectory
    case invalidHandoffDirectory
    case hookInputTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: AgentGitHookBridge guard --provider <codex|claude>, "
                + "inspect --token <token>, or register --token <token> "
                + "--title <title> --summary <summary>."
        case .invalidProvider:
            "Provider must be codex or claude."
        case .invalidDataDirectory:
            "AGENTGIT_DATA_DIRECTORY must be an absolute path."
        case .invalidHandoffDirectory:
            "AGENTGIT_HANDOFF_DIRECTORY must be an absolute path."
        case .hookInputTooLarge:
            "Hook input exceeds 1 MiB."
        }
    }
}
