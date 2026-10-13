import AgentGitCore
import AgentGitIntegrationShared
import SwiftUI

enum AgentGitSettingsSection: Hashable, CaseIterable, Identifiable {
    case review
    case worktrees
    case agents

    var id: Self { self }

    var title: String {
        switch self {
        case .review: "Review"
        case .worktrees: "Worktrees"
        case .agents: "Agents"
        }
    }

    var subtitle: String {
        switch self {
        case .review: "Configure diff presentation and review behavior."
        case .worktrees: "Automatically remove clean worktrees after a period of inactivity."
        case .agents: "Manage optional AgentGit integrations and local sessions."
        }
    }

    var systemImage: String {
        switch self {
        case .review: "rectangle.split.2x1"
        case .worktrees: "arrow.triangle.branch"
        case .agents: "sparkles.rectangle.stack"
        }
    }

    var preferredContentHeight: CGFloat {
        switch self {
        case .review: 590
        case .worktrees: 620
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
                    .font(.agentGitInterface(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Sources/ReviewView.swift")
                    .font(.agentGitInterface(size: 11.5, weight: .semibold))
                Spacer()
                Text("−2  +4")
                    .font(.agentGitInterface(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: AgentGitPalette.fileHeader))

            HStack {
                Text("renderReview()")
                    .font(.agentGitInterface(size: 10.5, design: .monospaced))
                Spacer()
                Text(layout.title)
                    .font(.agentGitInterface(size: 9.5, weight: .medium))
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
            .font(.agentGitInterface(size: 10.5, design: .monospaced))
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
                    .stroke(Color(nsColor: AgentGitPalette.cardBorder), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.025), radius: 8, y: 2)
    }
}

struct AgentGitSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedSection: AgentGitSettingsSection
    @State private var creatorHookInstalled: Bool?
    @State private var creatorHookError: String?
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
                        case .worktrees:
                            worktreeSettings
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
        .scaledFontPresentation(
            width: 820,
            height: fixedContentHeight ?? selectedSection.preferredContentHeight
        )
        .background(Color(nsColor: AgentGitPalette.canvas))
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
                        .font(.agentGitInterface(size: 13.5, weight: .semibold))
                    Text("Preferences")
                        .font(.agentGitInterface(size: 10.5))
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
                                .font(.agentGitInterface(size: 12.5, weight: .medium))
                            Spacer(minLength: 4)
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
                .font(.agentGitInterface(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
        .padding(16)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: AgentGitPalette.sidebarBackground))
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedSection.title)
                    .font(.agentGitInterface(size: 26, weight: .semibold))
                Text(selectedSection.subtitle)
                    .font(.agentGitInterface(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selectedSection == .agents {
                Label(
                    "\(model.agentAssociations.associations.count) sessions",
                    systemImage: "link"
                )
                .font(.agentGitInterface(size: 10.5, weight: .medium))
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
                    .font(.agentGitInterface(size: 12))
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

    private var worktreeSettings: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            AgentGitSettingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    settingsCardHeading(
                        "Automatic Cleanup",
                        detail: "Runs while AgentGit is open, including in the background.",
                        image: "clock.arrow.circlepath"
                    )
                    HStack {
                        Toggle("Automatically remove inactive worktrees", isOn: $model.cleanupSettings.isEnabled)
                            .toggleStyle(.switch)
                        Spacer(minLength: 8)
                        Button(model.isCleaningWorktrees ? "Cleaning…" : "Clean Up Now") {
                            Task { await model.runWorktreeCleanupNow() }
                        }
                        .disabled(model.isCleaningWorktrees || model.projects.isEmpty)
                        .help("Check and remove eligible worktrees now, using the current inactivity and exclusion settings.")
                    }
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                        GridRow {
                            settingsFieldLabel("Check every")
                            Picker("Check every", selection: $model.cleanupSettings.intervalHours) {
                                Text("Hour").tag(1)
                                Text("6 hours").tag(6)
                                Text("Day").tag(24)
                            }
                            .labelsHidden()
                            .disabled(!model.cleanupSettings.isEnabled)
                        }
                        GridRow {
                            settingsFieldLabel("Inactive for")
                            Picker("Inactive for", selection: $model.cleanupSettings.inactiveDays) {
                                ForEach([3, 7, 14, 30], id: \.self) { days in
                                    Text("\(days) days").tag(days)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    Text("Cleanup uses the activity time shown in the list. Main, pinned, selected, and locked worktrees are kept, as are worktrees with uncommitted changes or untracked files, including changes inside submodules. Clean worktrees with submodules can be removed. Ignored files are removed with eligible worktrees. Branches and referenced commits are preserved.")
                        .font(.agentGitInterface(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.projects.isEmpty {
                AgentGitSettingsCard {
                    VStack(alignment: .leading, spacing: 14) {
                        settingsCardHeading(
                            "Excluded Projects",
                            detail: "Checked projects are never automatically cleaned up, including worktrees added later.",
                            image: "folder.badge.minus"
                        )
                        ForEach(model.projects) { state in
                            Toggle(isOn: Binding(
                                get: { model.isProjectExcludedFromCleanup(id: state.id) },
                                set: { model.setProjectCleanupExcluded($0, id: state.id) }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(state.project.displayName)
                                        .font(.agentGitInterface(size: 12, weight: .medium))
                                    Text(state.project.rootURL.path)
                                        .font(.agentGitInterface(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .help(state.project.rootURL.path)
                        }
                    }
                }
            }
            AgentGitSettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    if model.isCleaningWorktrees {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Checking worktrees…")
                        }
                    } else if let report = model.cleanupReport {
                        Text("Last check: \(report.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .fontWeight(.medium)
                        Text("\(report.removedPaths.count) removed · \(report.skippedCount) kept · \(report.errors.count) errors")
                            .foregroundStyle(.secondary)
                        ForEach(report.removedPaths, id: \.self) { path in
                            Label(path, systemImage: "checkmark.circle")
                                .textSelection(.enabled)
                        }
                        ForEach(report.errors, id: \.self) { error in
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if let skipped = report.skippedWorktrees, !skipped.isEmpty {
                            DisclosureGroup("Kept worktrees") {
                                ForEach(skipped, id: \.path) { entry in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.path)
                                        Text(entry.reason).foregroundStyle(.secondary)
                                    }
                                    .textSelection(.enabled)
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                        Button("Copy Cleanup Details") {
                            copyToPasteboard(report.diagnosticText)
                        }
                    } else {
                        Text(model.cleanupSettings.isEnabled ? "Waiting for the first check." : "Automatic cleanup is off.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Show Logs in Finder") {
                        Task {
                            await AgentGitDiagnostics.shared.flush()
                            revealInFinder(AgentGitDiagnostics.shared.directoryURL)
                        }
                    }
                }
                .font(.agentGitInterface(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var agentSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentGitSettingsCard {
                worktreeCreatorHookSettings
            }
            AgentGitSettingsCard {
                agentSessionStorageSettings
            }
        }
    }

    private var worktreeCreatorHookSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardHeading(
                "Worktree Creator",
                detail: "A global git hook records which Claude or Codex session ran `git worktree add`. Requires Git 2.54 or later.",
                image: "arrow.triangle.branch"
            )

            HStack {
                Text(creatorHookInstalled.map {
                    $0 ? "Installed in global git config" : "Not installed"
                } ?? "Checking…")
                .font(.agentGitInterface(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                Spacer()
                if let installed = creatorHookInstalled {
                    Button(installed ? "Remove Hook" : "Install Hook") {
                        Task {
                            do {
                                try await installed
                                    ? WorktreeCreatorHook.uninstall()
                                    : WorktreeCreatorHook.install()
                                creatorHookError = nil
                            } catch {
                                creatorHookError = String(describing: error)
                            }
                            creatorHookInstalled = await WorktreeCreatorHook.isInstalled()
                        }
                    }
                }
            }

            if let creatorHookError {
                Text(creatorHookError)
                    .font(.agentGitInterface(.caption))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .task {
            creatorHookInstalled = await WorktreeCreatorHook.isInstalled()
        }
    }

    private var agentSessionStorageSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardHeading(
                "Agent Sessions",
                detail: "Associations stay on this Mac with private file permissions.",
                image: "link"
            )

            HStack {
                Text("Registered")
                    .font(.agentGitInterface(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.agentAssociations.associations.count)")
                    .font(.agentGitInterface(size: 12, weight: .semibold).monospacedDigit())
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
                    .font(.agentGitInterface(.caption))
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
                    .font(.agentGitInterface(.caption))
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
                .font(.agentGitInterface(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(
                    Color.accentColor.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.agentGitInterface(size: 13, weight: .semibold))
                Text(detail)
                    .font(.agentGitInterface(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.agentGitInterface(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 82, alignment: .leading)
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


}
