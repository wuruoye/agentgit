import AgentGitCore
import AgentGitIntegrationShared
import SwiftUI

enum AgentGitSettingsSection: Hashable {
    case review
    case agents

    var title: String {
        switch self {
        case .review: "Review"
        case .agents: "Agents"
        }
    }

    var preferredContentHeight: CGFloat {
        switch self {
        case .review: 280
        case .agents: 540
        }
    }
}

struct AgentGitSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedSection: AgentGitSettingsSection
    let fixedContentHeight: CGFloat?

    init(
        contentHeight: CGFloat? = nil,
        initialSection: AgentGitSettingsSection = .review
    ) {
        fixedContentHeight = contentHeight
        _selectedSection = State(initialValue: initialSection)
    }

    private static let contextChoices: [GitDiffContext] = [
        .lines(3), .lines(8), .lines(25), .wholeFile
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings Section", selection: $selectedSection) {
                Text(AgentGitSettingsSection.review.title)
                    .tag(AgentGitSettingsSection.review)
                Text(AgentGitSettingsSection.agents.title)
                    .tag(AgentGitSettingsSection.agents)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            switch selectedSection {
            case .review:
                reviewSettings
            case .agents:
                agentSettings
            }
        }
        .frame(
            width: 560,
            height: fixedContentHeight ?? selectedSection.preferredContentHeight
        )
        .task(id: model.isApplicationActive && selectedSection == .agents) {
            guard model.isApplicationActive, selectedSection == .agents else {
                return
            }
            await model.agentPluginConfigurator.refresh()
        }
    }

    private var reviewSettings: some View {
        Form {
            Section("Diff") {
                Picker("Layout", selection: layoutBinding) {
                    ForEach(DiffLayoutMode.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Context", selection: contextBinding) {
                    ForEach(Self.contextChoices, id: \.self) { context in
                        Text(context.title).tag(context)
                    }
                }

                Toggle("Ignore whitespace changes", isOn: ignoresWhitespaceBinding)
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private var agentSettings: some View {
        Form {
            Section("Agent Integrations") {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    let status = pluginStatus(provider)
                    let plugin = AgentIntegrationPlugin.plugin(for: provider)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 9) {
                            Image(systemName: provider.systemImageName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(provider.tintColor)
                                .frame(width: 24, height: 24)
                                .background(
                                    provider.tintColor.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                    .font(.body.weight(.medium))
                                Text(pluginCapabilityDescription(plugin))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(integrationStatusColor(status))
                                .frame(width: 7, height: 7)
                            Text(status.title)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if status == .configuring
                                || status == .disabling
                                || status == .notChecked {
                                ProgressView()
                                    .controlSize(.small)
                            } else if status == .configured {
                                Button("Disable") {
                                    Task {
                                        await model.agentPluginConfigurator.disable(provider)
                                    }
                                }
                            } else if let actionTitle = integrationActionTitle(status) {
                                Button(actionTitle) {
                                    Task {
                                        await model.agentPluginConfigurator.enable(provider)
                                    }
                                }
                            }
                        }
                        if case let .failed(message) = status {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        } else if status == .needsUpdate {
                            Text("A newer AgentGit integration plugin is available.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let event = model.agentAssociations.latestRegistrationEvent(
                            for: provider
                        ) {
                            Text(
                                "\(registrationEventTitle(event)) · "
                                    + compactRelativeTime(event.createdAt)
                            )
                            .font(.caption)
                            .foregroundStyle(registrationEventColor(event))
                            .help(event.message)
                        } else if status == .configured {
                            Text("Waiting for the first repository write registration.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("Skill Runtime") {
                    Text(skillBridgePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Text(
                    "Each integration is installed through the agent's official plugin CLI and can "
                        + "be enabled independently. The registration Skill checks the current "
                        + "worktree, organizes session details, and calls the local Skill runtime."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Agent Sessions") {
                LabeledContent("Registered") {
                    Text("\(model.agentAssociations.associations.count)")
                        .monospacedDigit()
                }

                if let persistenceError = model.agentAssociations.persistenceErrorMessage {
                    Label("Session storage is unavailable", systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.red)
                    Text(persistenceError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(persistenceError)
                    Button("Repair Storage") {
                        model.agentAssociations.repairPersistence()
                    }
                    .disabled(!model.agentAssociations.canRepairPersistence)
                } else {
                    Text(
                        "Session associations are stored locally with private file permissions. "
                            + "Remove an association from its session button context menu."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let recoveryMessage = model.agentAssociations.recoveryMessage {
                    Text(recoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(recoveryMessage)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private var layoutBinding: Binding<DiffLayoutMode> {
        Binding(
            get: { model.diffLayout },
            set: { model.diffLayout = $0 }
        )
    }

    private var contextBinding: Binding<GitDiffContext> {
        Binding(
            get: { model.diffOptions.context },
            set: { context in
                var options = model.diffOptions
                options.context = context
                model.diffOptions = options
            }
        )
    }

    private var ignoresWhitespaceBinding: Binding<Bool> {
        Binding(
            get: { model.diffOptions.ignoresWhitespace },
            set: { ignoresWhitespace in
                var options = model.diffOptions
                options.ignoresWhitespace = ignoresWhitespace
                model.diffOptions = options
            }
        )
    }

    private func pluginStatus(_ provider: AgentProvider) -> AgentPluginConfigurationStatus {
        model.agentPluginConfigurator.statusByProvider[provider] ?? .notChecked
    }

    private func integrationStatusColor(
        _ status: AgentPluginConfigurationStatus
    ) -> Color {
        switch status {
        case .configured: .green
        case .configuring, .disabling, .notChecked: .secondary
        case .notConfigured, .needsUpdate: .orange
        case .failed: .red
        }
    }

    private func integrationActionTitle(
        _ status: AgentPluginConfigurationStatus
    ) -> String? {
        switch status {
        case .notConfigured: "Enable"
        case .needsUpdate: "Update"
        case .failed: "Retry"
        case .notChecked, .configuring, .disabling, .configured: nil
        }
    }

    private func pluginCapabilityDescription(
        _ plugin: AgentIntegrationPlugin
    ) -> String {
        plugin.capabilities.map(\.rawValue).joined(separator: " · ")
    }

    private var skillBridgePath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/AgentGitSkillBridge")
            .path
    }

    private func registrationEventTitle(
        _ event: AgentRegistrationEvent
    ) -> String {
        switch (event.action, event.outcome) {
        case (.register, .succeeded):
            "Session registered"
        case (.register, .rejected):
            "Registration rejected"
        case (.register, .failed):
            "Registration failed"
        case (.unregister, .succeeded):
            "Session removed"
        case (.unregister, .rejected):
            "Removal rejected"
        case (.unregister, .failed):
            "Removal failed"
        }
    }

    private func registrationEventColor(
        _ event: AgentRegistrationEvent
    ) -> Color {
        switch event.outcome {
        case .succeeded: .secondary
        case .rejected: .orange
        case .failed: .red
        }
    }

}
