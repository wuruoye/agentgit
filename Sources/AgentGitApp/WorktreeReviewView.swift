import AgentGitCore
import SwiftUI

private struct ReviewVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isReviewVisible: Bool {
        get { self[ReviewVisibilityKey.self] }
        set { self[ReviewVisibilityKey.self] = newValue }
    }
}

private struct WorkspaceSearchActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var workspaceSearchAction: (() -> Void)? {
        get { self[WorkspaceSearchActionKey.self] }
        set { self[WorkspaceSearchActionKey.self] = newValue }
    }
}

struct WorktreeReviewView: View {
    @Environment(AppModel.self) private var model

    let snapshot: GitWorktreeSnapshot
    var focusMode: Binding<Bool> = .constant(false)

    var body: some View {
        let initialNavigationState = model.reviewStates.lastContext(
            for: snapshot.id
        )
        let startupContent = model.startupReviewContent(for: snapshot)
        IntegratedReviewWorkspace(
            snapshot: snapshot,
            startupContent: startupContent,
            initialContext: initialNavigationState.context,
            initialSelectedCommitIDs: initialNavigationState.selectedCommitIDs,
            initialPane: initialNavigationState.pane,
            initialHistoryFilter: initialNavigationState.historyFilter,
            focusMode: focusMode,
            initialReviewState: model.reviewStates.state(
                for: ReviewStateKey(
                    worktreeID: snapshot.id,
                    context: initialNavigationState.context
                )
            )
        )
    }
}

struct ReviewCommandActions {
    let navigateBack: () -> Void
    let navigateForward: () -> Void
    let canNavigateBack: Bool
    let canNavigateForward: Bool
    let selectNext: () -> Void
    let selectPrevious: () -> Void
    let focusFilter: () -> Void
    let showCommits: () -> Void
    let showFiles: () -> Void
    let navigatorDefaultActionTitle: String?
    let performNavigatorDefaultAction: () -> Void
    let canDiscardFocusedFile: Bool
    let requestFocusedFileDiscard: () -> Void
    let collapseAllFiles: () -> Void
    let expandAllFiles: () -> Void
}

private struct ReviewCommandActionsKey: FocusedValueKey {
    typealias Value = ReviewCommandActions
}

extension FocusedValues {
    var reviewCommandActions: ReviewCommandActions? {
        get { self[ReviewCommandActionsKey.self] }
        set { self[ReviewCommandActionsKey.self] = newValue }
    }
}

struct AgentGitReviewCommands: Commands {
    @FocusedValue(\.reviewCommandActions) private var actions
    @FocusedValue(\.workspaceSearchAction) private var workspaceSearchAction

    var body: some Commands {
        CommandMenu("Review") {
            Button("Collapse All Files") { actions?.collapseAllFiles() }
                .disabled(actions == nil)
            Button("Expand All Files") { actions?.expandAllFiles() }
                .disabled(actions == nil)
            Divider()
            Button("Navigate Back") {
                actions?.navigateBack()
            }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(actions?.canNavigateBack != true)
            Button("Navigate Forward") {
                actions?.navigateForward()
            }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(actions?.canNavigateForward != true)

            Divider()

            Button("Next File") {
                actions?.selectNext()
            }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(actions == nil)
            Button("Previous File") {
                actions?.selectPrevious()
            }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(actions == nil)

            Divider()

            Button(
                actions?.navigatorDefaultActionTitle
                    ?? "Stage or Unstage Focused File"
            ) {
                actions?.performNavigatorDefaultAction()
            }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(actions?.navigatorDefaultActionTitle == nil)
            Button("Discard Focused File") {
                actions?.requestFocusedFileDiscard()
            }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(actions?.canDiscardFocusedFile != true)

            Divider()

            Button("Focus Filter") {
                if let workspaceSearchAction { workspaceSearchAction() }
                else { actions?.focusFilter() }
            }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil && workspaceSearchAction == nil)

            Divider()

            // 聚焦历史时同时展开被收起的历史区域。
            Button("Focus Commits") {
                actions?.showCommits()
            }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(actions == nil)
            Button("Focus Files") {
                actions?.showFiles()
            }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(actions == nil)
        }
    }
}
