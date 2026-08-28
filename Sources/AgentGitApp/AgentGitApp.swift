import AppKit
import SwiftUI

@main
struct AgentGitApp: App {
    @NSApplicationDelegateAdaptor(AgentGitApplicationDelegate.self)
    private var applicationDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("AgentGit") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1_200, minHeight: 680)
                .onAppear {
                    applicationDelegate.attach(model)
                }
        }
        .defaultSize(width: 1440, height: 840)
        .windowToolbarStyle(.unified)
        .commands {
            AgentGitReviewCommands()

            CommandGroup(replacing: .newItem) {
                Button("Add Git Project…", action: model.chooseProject)
                    .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Project") {
                Button("Switch Worktree…") {
                    model.isWorktreeSwitcherPresented = true
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!model.hasAvailableWorktrees)

                Divider()

                Button("Refresh Current Worktree") {
                    Task {
                        await model.refreshSelectedWorktree()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selectedWorktree == nil)

                Button("Refresh All Projects") {
                    Task {
                        await model.refreshAll()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            AgentGitSettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AgentGitApplicationDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var isPreparingTermination = false

    func attach(_ model: AppModel) {
        self.model = model
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let model else {
            return .terminateNow
        }
        guard !isPreparingTermination else {
            return .terminateLater
        }
        isPreparingTermination = true
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
