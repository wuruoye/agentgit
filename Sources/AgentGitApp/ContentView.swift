import AgentGitCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.selectedWorktreeID) {
                ForEach(model.projects) { projectState in
                    Section {
                        projectContents(projectState)
                    } header: {
                        ProjectHeader(projectState: projectState)
                            .contextMenu {
                                Button("Refresh") {
                                    Task {
                                        await model.refreshProject(id: projectState.id)
                                    }
                                }
                                Divider()
                                Button("Remove Project", role: .destructive) {
                                    model.removeProject(id: projectState.id)
                                }
                            }
                    }
                }
            }
            .navigationTitle("Worktrees")
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        Task {
                            await model.refreshAll()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button(action: model.chooseProject) {
                        Label("Add Project", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let snapshot = model.selectedWorktree {
                WorktreeReviewView(snapshot: snapshot)
            } else {
                ContentUnavailableView {
                    Label(
                        "No Worktree Selected",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                } description: {
                    Text("Add a Git project to discover all of its worktrees.")
                } actions: {
                    Button("Add Project", action: model.chooseProject)
                }
            }
        }
        .task {
            await model.loadProjectsIfNeeded()
        }
    }

    @ViewBuilder
    private func projectContents(_ state: ProjectState) -> some View {
        if state.isLoading, state.snapshot == nil {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading worktrees…")
                    .foregroundStyle(.secondary)
            }
        }

        if let errorMessage = state.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }

        if let snapshot = state.snapshot {
            ForEach(snapshot.worktrees) { worktree in
                WorktreeRow(snapshot: worktree)
                    .tag(worktree.id)
            }
        }
    }
}

private struct ProjectHeader: View {
    let projectState: ProjectState

    var body: some View {
        HStack(spacing: 6) {
            Text(projectState.project.displayName)
                .lineLimit(1)
            if projectState.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer(minLength: 4)
            if let count = projectState.snapshot?.worktrees.count {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .help(projectState.project.rootURL.path)
    }
}

private struct WorktreeRow: View {
    let snapshot: GitWorktreeSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snapshot.worktree.displayName)
                        .lineLimit(1)
                    if snapshot.status.changedFileCount > 0 {
                        Text("\(snapshot.status.changedFileCount)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.16), in: Capsule())
                    }

                    Spacer(minLength: 4)

                    if !snapshot.diffStat.isEmpty {
                        HStack(spacing: 4) {
                            Text("+\(snapshot.diffStat.addedLineCount)")
                                .foregroundStyle(.green)
                            Text("−\(snapshot.diffStat.deletedLineCount)")
                                .foregroundStyle(.red)
                        }
                        .font(.caption2.monospacedDigit().weight(.medium))
                    }
                }

                HStack(spacing: 5) {
                    Text(snapshot.worktree.rootURL.lastPathComponent)
                        .lineLimit(1)
                    if let shortHeadOID = snapshot.worktree.shortHeadOID {
                        Text("·")
                        Text(shortHeadOID)
                            .font(.caption.monospaced())
                    }
                    Text("·")
                    if snapshot.lastActivityAt == .distantPast {
                        Text("Unknown activity")
                    } else {
                        Text(snapshot.lastActivityAt, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let errorMessage = snapshot.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
        .help(snapshot.worktree.rootURL.path)
    }

    private var iconName: String {
        if snapshot.errorMessage != nil {
            return "exclamationmark.triangle.fill"
        }
        return snapshot.worktree.isDetached ? "link" : "arrow.triangle.branch"
    }

    private var iconColor: Color {
        if snapshot.errorMessage != nil {
            return .red
        }
        return snapshot.status.changedFileCount == 0 ? .secondary : .orange
    }
}
