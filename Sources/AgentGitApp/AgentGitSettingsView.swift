import AgentGitCore
import AgentGitIntegrationShared
import SwiftUI

enum AgentGitSettingsSection: Hashable, CaseIterable, Identifiable {
    case review
    case agents

    var id: Self { self }

    var title: String {
        switch self {
        case .review: "Review"
        case .agents: "Agents"
        }
    }

    var subtitle: String {
        switch self {
        case .review: "Configure diff presentation and review behavior."
        case .agents: "Manage optional AgentGit integrations and local sessions."
        }
    }

    var systemImage: String {
        switch self {
        case .review: "rectangle.split.2x1"
        case .agents: "sparkles.rectangle.stack"
        }
    }

    var preferredContentHeight: CGFloat {
        switch self {
        case .review: 590
        case .agents: 620
        }
    }
}

private struct ReviewSettingsPreview: View {
    let layout: DiffLayoutMode

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 23)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Sources/ReviewView.swift")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text("−2  +4")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: AgentGitPalette.fileHeader))

            HStack {
                Text("renderReview()")
                    .font(.system(size: 10.5, design: .monospaced))
                Spacer()
                Text(layout.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(nsColor: AgentGitPalette.hunkHeader))

            if layout == .sideBySide {
                HStack(spacing: 0) {
                    codePreview(isAddition: false)
                    Divider()
                    codePreview(isAddition: true)
                }
            } else {
                VStack(spacing: 0) {
                    codeLine("− let state = oldValue", isAddition: false)
                    codeLine("+ let state = newValue", isAddition: true)
                }
            }
        }
        .background(Color(nsColor: AgentGitPalette.canvas))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: AgentGitPalette.reviewControlBorder), lineWidth: 1)
        }
    }

    private func codePreview(isAddition: Bool) -> some View {
        codeLine(
            isAddition ? "+ let state = newValue" : "− let state = oldValue",
            isAddition: isAddition
        )
    }

    private func codeLine(_ text: String, isAddition: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                Color(
                    nsColor: isAddition
                        ? AgentGitPalette.additionBackground
                        : AgentGitPalette.deletionBackground
                )
            )
    }
}

private struct AgentGitSettingsCard<Content: View>: View {
    let accent: Color
    @ViewBuilder let content: Content

    init(
        accent: Color = .secondary,
        @ViewBuilder content: () -> Content
    ) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: AgentGitPalette.reviewControlBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accent.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
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
        HStack(spacing: 0) {
            settingsSidebar
            Divider()

            VStack(spacing: 0) {
                settingsHeader
                Divider()

                ScrollView {
                    Group {
                        switch selectedSection {
                        case .review:
                            reviewSettings
                        case .agents:
                            agentSettings
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            width: 820,
            height: fixedContentHeight ?? selectedSection.preferredContentHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.isApplicationActive && selectedSection == .agents) {
            guard model.isApplicationActive, selectedSection == .agents else {
                return
            }
            await model.agentPluginConfigurator.refresh()
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AgentGit")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("Preferences")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 6) {
                ForEach(AgentGitSettingsSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.systemImage)
                                .frame(width: 20)
                            Text(section.title)
                                .font(.system(size: 12.5, weight: .medium))
                            Spacer(minLength: 4)
                            if section == .agents {
                                Circle()
                                    .fill(agentIntegrationSummaryColor)
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .foregroundStyle(
                            selectedSection == section
                                ? Color.accentColor
                                : Color.primary
                        )
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            selectedSection == section
                                ? Color.accentColor.opacity(0.11)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(section.title)
                    .accessibilityValue(
                        selectedSection == section ? "Selected" : ""
                    )
                }
            }

            Spacer(minLength: 16)

            Label("Local configuration", systemImage: "lock.shield")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
        .padding(16)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedSection.title)
                    .font(.system(size: 20, weight: .semibold))
                Text(selectedSection.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selectedSection == .agents {
                Label(
                    "\(model.agentAssociations.associations.count) sessions",
                    systemImage: "link"
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.07), in: Capsule())
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var reviewSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentGitSettingsCard(accent: .accentColor) {
                VStack(alignment: .leading, spacing: 16) {
                    settingsCardHeading(
                        "Diff Presentation",
                        detail: "Choose the layout and context used throughout the Review workspace.",
                        image: "rectangle.split.2x1"
                    )

                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                        GridRow {
                            settingsFieldLabel("Layout")
                            Picker("Layout", selection: layoutBinding) {
                                ForEach(DiffLayoutMode.allCases) { layout in
                                    Text(layout.title).tag(layout)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        GridRow {
                            settingsFieldLabel("Context")
                            Picker("Context", selection: contextBinding) {
                                ForEach(Self.contextChoices, id: \.self) { context in
                                    Text(context.title).tag(context)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GridRow {
                            settingsFieldLabel("Comparison")
                            Toggle(
                                "Ignore whitespace changes",
                                isOn: ignoresWhitespaceBinding
                            )
                            .toggleStyle(.switch)
                        }
                    }
                    .font(.system(size: 12))
                }
            }

            AgentGitSettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    settingsCardHeading(
                        "Live Preview",
                        detail: "The preview uses the same hierarchy as file and hunk headers.",
                        image: "rectangle.and.text.magnifyingglass"
                    )
                    ReviewSettingsPreview(layout: model.diffLayout)
                }
            }
        }
    }

    private var agentSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentGitSettingsCard(accent: agentIntegrationSummaryColor) {
                VStack(alignment: .leading, spacing: 0) {
                    settingsCardHeading(
                        "Agent Integrations",
                        detail: "Each provider can enable the AgentGit registration Skill independently.",
                        image: "sparkles.rectangle.stack"
                    )
                    .padding(.bottom, 8)

                    ForEach(Array(AgentProvider.allCases.enumerated()), id: \.element) {
                        index,
                        provider in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 39)
                        }
                        integrationRow(provider)
                            .padding(.vertical, 10)
                    }
                }
            }

            AgentGitSettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    settingsCardHeading(
                        "Skill Runtime",
                        detail: "The bundled helper receives registration data from each provider Skill.",
                        image: "terminal"
                    )
                    Text(skillBridgePath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color(nsColor: AgentGitPalette.inputBackground),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
            }

            AgentGitSettingsCard {
                agentSessionStorageSettings
            }
        }
    }

    private func integrationRow(_ provider: AgentProvider) -> some View {
        let status = pluginStatus(provider)
        let plugin = AgentIntegrationPlugin.plugin(for: provider)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: provider.systemImageName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(provider.tintColor)
                    .frame(width: 28, height: 28)
                    .background(
                        provider.tintColor.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(pluginCapabilityDescription(plugin))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Circle()
                    .fill(integrationStatusColor(status))
                    .frame(width: 7, height: 7)
                Text(status.title)
                    .font(.system(size: 11))
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
                    .controlSize(.small)
                } else if let actionTitle = integrationActionTitle(status) {
                    Button(actionTitle) {
                        Task {
                            await model.agentPluginConfigurator.enable(provider)
                        }
                    }
                    .controlSize(.small)
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

    @ViewBuilder
    private var agentSessionStorageSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardHeading(
                "Agent Sessions",
                detail: "Associations stay on this Mac with private file permissions.",
                image: "link"
            )

            HStack {
                Text("Registered")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.agentAssociations.associations.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.07), in: Capsule())
            }

            if let persistenceError = model.agentAssociations.persistenceErrorMessage {
                Label(
                    "Session storage is unavailable",
                    systemImage: "externaldrive.badge.exclamationmark"
                )
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

    private func settingsCardHeading(
        _ title: String,
        detail: String,
        image: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: image)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(
                    Color.accentColor.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 82, alignment: .leading)
    }

    private var agentIntegrationSummaryColor: Color {
        let statuses = AgentProvider.allCases.map(pluginStatus)
        if statuses.contains(where: { status in
            if case .failed = status {
                return true
            }
            return false
        }) {
            return .red
        }
        if statuses.allSatisfy({ $0 == .configured }) {
            return .green
        }
        return .orange
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
