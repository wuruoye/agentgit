import AgentGitCore
import AgentGitIntegrationShared
import SwiftUI
import UniformTypeIdentifiers

enum AgentGitSettingsSection: Hashable, CaseIterable, Identifiable {
    case review
    case worktrees
    case openWith
    case agents

    var id: Self { self }

    var title: String {
        switch self {
        case .review: "Review"
        case .worktrees: "Worktrees"
        case .openWith: "Open With"
        case .agents: "Agents"
        }
    }

    var subtitle: String {
        switch self {
        case .review: "Configure diff presentation and review behavior."
        case .worktrees: "Automatically remove clean worktrees after a period of inactivity."
        case .openWith: "Add applications to the worktree context menu for each repository."
        case .agents: "Manage optional AgentGit integrations and local sessions."
        }
    }

    var systemImage: String {
        switch self {
        case .review: "rectangle.split.2x1"
        case .worktrees: "arrow.triangle.branch"
        case .openWith: "arrow.up.forward.app"
        case .agents: "sparkles.rectangle.stack"
        }
    }

    var preferredContentHeight: CGFloat {
        switch self {
        case .review: 590
        case .worktrees: 620
        case .openWith: 620
        case .agents: 620
        }
    }
}

/// 从右键菜单跳到设置时要打开的分区和仓库。
struct AgentGitSettingsDestination: Equatable {
    let section: AgentGitSettingsSection
    var projectID: GitProject.ID?
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
    @State private var collapseRulesProjectID: GitProject.ID?
    @State private var openWithProjectID: GitProject.ID?
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
    private static let openWithChooseTitles = ["Choose App…", "Choose Folder…"]

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
                        case .openWith:
                            openWithSettings
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
        .onAppear {
            collapseRulesProjectID = model.projectID(for: model.selectedWorktreeID)
            openWithProjectID = collapseRulesProjectID
            applyRequestedDestination()
        }
        .onChange(of: model.requestedSettingsDestination) {
            applyRequestedDestination()
        }
    }

    private func applyRequestedDestination() {
        guard let destination = model.requestedSettingsDestination else { return }
        selectedSection = destination.section
        if let projectID = destination.projectID {
            openWithProjectID = projectID
        }
        model.requestedSettingsDestination = nil
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
                commitCollapseRulesSettings
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

    private var collapseRulesProject: ProjectState? {
        let projectID = collapseRulesProjectID ?? model.projectID(for: model.selectedWorktreeID)
        return model.projects.first { $0.id == projectID } ?? model.projects.first
    }

    private var commitCollapseRulesSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardHeading(
                "Collapsed Files in Commits",
                detail: "Rules are saved separately for each repository and shared by its worktrees. Matching files start collapsed when you open a commit or commit range. You can expand them manually.",
                image: "chevron.right.square"
            )
            if let project = collapseRulesProject {
                repositoryPicker(project) { collapseRulesProjectID = $0 }

                TextEditor(text: Binding(
                    get: { model.commitFileCollapseSettings.text(for: project.id) },
                    set: { model.commitFileCollapseSettings.setText($0, for: project.id) }
                ))
                .font(.agentGitInterface(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 108)
                .background(Color(nsColor: AgentGitPalette.canvas))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: AgentGitPalette.reviewControlBorder), lineWidth: 1)
                }
                .id(project.id)
                .accessibilityLabel("Commit file collapse rules")

                Text(verbatim: "One rule per line. Use * for any characters in a name, ? for one character, and ** across directories. Rules with / match paths from the repository root; other rules match filenames anywhere. Matching is case-sensitive. Blank lines and # comments are ignored. Changes are saved automatically.")
                    .font(.agentGitInterface(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "Examples: *.lock · *.pb.swift · **/generated/**")
                    .font(.agentGitInterface(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("Add a Git project to configure its commit file rules.")
                    .font(.agentGitInterface(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func repositoryPicker(
        _ project: ProjectState,
        select: @escaping (GitProject.ID) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Repository", selection: Binding(
                get: { project.id },
                set: select
            )) {
                ForEach(model.projects) { state in
                    Text("\(state.project.displayName) · \(state.project.rootURL.deletingLastPathComponent().path)")
                        .tag(state.id)
                }
            }
            .font(.agentGitInterface(size: 12))

            Text(verbatim: project.project.rootURL.path)
                .font(.agentGitInterface(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var openWithProject: ProjectState? {
        let projectID = openWithProjectID ?? model.projectID(for: model.selectedWorktreeID)
        return model.projects.first { $0.id == projectID } ?? model.projects.first
    }

    private var openWithSettings: some View {
        AgentGitSettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                settingsCardHeading(
                    "Worktree Context Menu",
                    detail: "Applications are saved separately for each repository and shared by its worktrees. They appear after Open with Visual Studio Code when you right-click a worktree.",
                    image: "arrow.up.forward.app"
                )
                if let project = openWithProject {
                    repositoryPicker(project) { openWithProjectID = $0 }

                    let entries = model.openWithSettings.entries(for: project.id)
                    if entries.isEmpty {
                        Text("No applications for this repository yet.")
                            .font(.agentGitInterface(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        openWithEntryEditor(entry, project: project)
                    }
                    Button("Add Application…") {
                        addOpenWithApplication(to: project)
                    }

                    Text(verbatim: "Folder is relative to the root of the worktree you right-click, for example MMFlutter/CrossPlatform. Leave it empty to open the worktree root. Absolute paths, “..”, and symbolic links that lead outside the worktree are rejected. Changes are saved automatically.")
                        .font(.agentGitInterface(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Add a Git project to configure its applications.")
                        .font(.agentGitInterface(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func openWithEntryEditor(
        _ entry: WorktreeOpenWithEntry,
        project: ProjectState
    ) -> some View {
        let applicationURL = entry.applicationURL()
        let title = entry.menuTitle(applicationURL: applicationURL)
        let folderStatus: (text: String, isError: Bool) = {
            do {
                let folder = try WorktreeOpenWithPath.normalize(entry.relativePath)
                return (folder.isEmpty ? "Opens the worktree root." : "Opens <worktree>/\(folder)", false)
            } catch {
                return (error.localizedDescription, true)
            }
        }()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(
                    forFile: applicationURL?.path ?? "/Applications"
                ))
                .resizable()
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.agentGitInterface(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(applicationURL.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        ?? "Application not found")
                        .font(.agentGitInterface(size: 10.5))
                        .foregroundStyle(applicationURL == nil ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button {
                    model.openWithSettings.remove(id: entry.id, for: project.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove from the context menu")
                .accessibilityLabel("Remove \(title)")
            }
            // 两个选择按钮按较长的标题取同一宽度，左侧输入框也就一样宽。
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    settingsFieldLabel("Name")
                    TextField(
                        "Name",
                        text: openWithBinding(entry, project: project, \.name),
                        prompt: Text(entry.applicationName(for: applicationURL))
                    )
                    .labelsHidden()
                }
                GridRow {
                    settingsFieldLabel("Bundle ID")
                    HStack {
                        TextField(
                            "Bundle ID",
                            text: Binding(
                                get: { entry.bundleIdentifier },
                                set: { identifier in
                                    // 手填 bundle id 时不再使用之前选的 .app 路径。
                                    updateOpenWithEntry(entry.id, project: project) {
                                        $0.bundleIdentifier = identifier
                                        $0.applicationPath = ""
                                    }
                                }
                            ),
                            prompt: Text("com.example.App")
                        )
                        .labelsHidden()
                        Button {
                            if let url = chooseApplicationURL() {
                                updateOpenWithEntry(entry.id, project: project) {
                                    $0.applicationPath = url.path
                                    $0.bundleIdentifier = Bundle(url: url)?.bundleIdentifier ?? ""
                                }
                            }
                        } label: {
                            StableButtonTitle(title: "Choose App…", alternatives: Self.openWithChooseTitles)
                        }
                    }
                }
                GridRow {
                    settingsFieldLabel("Folder")
                    HStack {
                        TextField(
                            "Folder",
                            text: openWithBinding(entry, project: project, \.relativePath),
                            prompt: Text("Worktree root")
                        )
                        .labelsHidden()
                        Button {
                            chooseOpenWithFolder(for: entry, project: project)
                        } label: {
                            StableButtonTitle(title: "Choose Folder…", alternatives: Self.openWithChooseTitles)
                        }
                    }
                }
                GridRow {
                    Color.clear.frame(width: 82, height: 1)
                    Text(folderStatus.text)
                        .font(.agentGitInterface(size: 10.5))
                        .foregroundStyle(folderStatus.isError ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folderStatus.text)
                }
            }
            .font(.agentGitInterface(size: 12))
        }
        .padding(12)
        .background(
            Color(nsColor: AgentGitPalette.canvas),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: AgentGitPalette.reviewControlBorder), lineWidth: 1)
        }
    }

    private func openWithBinding(
        _ entry: WorktreeOpenWithEntry,
        project: ProjectState,
        _ keyPath: WritableKeyPath<WorktreeOpenWithEntry, String>
    ) -> Binding<String> {
        Binding(
            get: { entry[keyPath: keyPath] },
            set: { value in
                updateOpenWithEntry(entry.id, project: project) { $0[keyPath: keyPath] = value }
            }
        )
    }

    /// 每次都从存储里取最新的配置再改，避免用到界面上一轮留下的旧值。
    private func updateOpenWithEntry(
        _ id: WorktreeOpenWithEntry.ID,
        project: ProjectState,
        change: (inout WorktreeOpenWithEntry) -> Void
    ) {
        guard var entry = model.openWithSettings.entries(for: project.id)
            .first(where: { $0.id == id }) else { return }
        change(&entry)
        model.openWithSettings.update(entry, for: project.id)
    }

    private func addOpenWithApplication(to project: ProjectState) {
        guard let url = chooseApplicationURL() else { return }
        model.openWithSettings.append(
            WorktreeOpenWithEntry(
                applicationPath: url.path,
                bundleIdentifier: Bundle(url: url)?.bundleIdentifier ?? ""
            ),
            for: project.id
        )
    }

    private func chooseApplicationURL() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 在仓库的任一 worktree 里选文件夹，换算成相对该 worktree 根目录的路径。
    private func chooseOpenWithFolder(for entry: WorktreeOpenWithEntry, project: ProjectState) {
        let worktreeRootURLs = (project.snapshot?.worktrees.map(\.worktree.rootURL) ?? [])
            + [project.project.rootURL]
        let selectedRootURL = model.projectID(for: model.selectedWorktreeID) == project.id
            ? model.selectedWorktree?.worktree.rootURL
            : nil
        let rootURL = selectedRootURL ?? project.project.rootURL
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = (try? WorktreeOpenWithPath.resolveDirectory(entry.relativePath, in: rootURL))
            ?? rootURL
        panel.prompt = "Choose Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let relativePath = WorktreeOpenWithPath.relativePath(of: url, inAnyOf: worktreeRootURLs) else {
            presentOpenWithFailure(
                title: "Folder Is Outside the Repository",
                message: "Choose a folder inside one of the worktrees of \(project.project.displayName)."
            )
            return
        }
        updateOpenWithEntry(entry.id, project: project) { $0.relativePath = relativePath }
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
                        Button {
                            Task { await model.runWorktreeCleanupNow() }
                        } label: {
                            StableButtonTitle(
                                title: model.isCleaningWorktrees ? "Cleaning…" : "Clean Up Now",
                                alternatives: ["Cleaning…", "Clean Up Now"]
                            )
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
                    HStack {
                        Button("Show Logs in Finder") {
                            Task {
                                await AgentGitDiagnostics.shared.flush()
                                revealInFinder(AgentGitDiagnostics.shared.directoryURL)
                            }
                        }
                        Button("Copy Cleanup Details") {
                            if let report = model.cleanupReport {
                                copyToPasteboard(report.diagnosticText)
                            }
                        }
                        .disabled(model.isCleaningWorktrees)
                        .workspaceControlSlot(isVisible: model.cleanupReport != nil)
                    }
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
                    } else {
                        Text(model.cleanupSettings.isEnabled ? "Waiting for the first check." : "Automatic cleanup is off.")
                            .foregroundStyle(.secondary)
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
                Button {
                    if let installed = creatorHookInstalled {
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
                } label: {
                    StableButtonTitle(
                        title: creatorHookInstalled == true ? "Remove Hook" : "Install Hook",
                        alternatives: ["Remove Hook", "Install Hook"]
                    )
                }
                .workspaceControlSlot(isVisible: creatorHookInstalled != nil)
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
