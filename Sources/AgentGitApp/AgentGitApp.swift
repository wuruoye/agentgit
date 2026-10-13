import AppKit
import AgentGitCore
import SwiftUI

enum AgentGitWindowMetrics {
    static let minimumWidth: CGFloat = 1_040
    static let minimumHeight: CGFloat = 680
    static let defaultWidth: CGFloat = 1_440
    static let defaultHeight: CGFloat = 840
}

@main
struct AgentGitApp: App {
    @NSApplicationDelegateAdaptor(AgentGitApplicationDelegate.self)
    private var applicationDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("AgentGit") {
            ContentView()
                .environment(model)
                .font(.agentGitInterface(.body))
                .frame(
                    minWidth: AgentGitWindowMetrics.minimumWidth,
                    minHeight: AgentGitWindowMetrics.minimumHeight
                )
                .onAppear {
                    applicationDelegate.attach(model)
                }
        }
        .defaultSize(
            width: AgentGitWindowMetrics.defaultWidth,
            height: AgentGitWindowMetrics.defaultHeight
        )
        .windowToolbarStyle(.unified)
        .commands {
            AgentGitReviewCommands()
            FontScaleCommands()

            // 不能替换掉 newItem：那会连系统的 New Window 一起删掉，
            // 窗口一旦关闭就再也开不回来，App 只剩一个没有界面的进程。
            CommandGroup(after: .newItem) {
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

                Button("Refresh Current Project") {
                    Task {
                        await model.refreshSelectedProject()
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
                .font(.agentGitInterface(.body))
        }
    }
}

@MainActor
final class AgentGitApplicationDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var isPreparingTermination = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let executableDate = try? Bundle.main.executableURL?.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        AgentGitDiagnostics.shared.record("app.start", fields: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "bundle": Bundle.main.bundleURL.path,
            "interfaceFont": AgentGitTypography.interface().fontName,
            "executableModifiedAt": executableDate?.ISO8601Format() ?? "",
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString
        ])
        guard let appearanceName = requestedVisualTestAppearance(
            environment: ProcessInfo.processInfo.environment
        ) else {
            return
        }
        NSApp.appearance = NSAppearance(named: appearanceName)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontScaleSettings.shared.installKeyboardShortcuts()
        Task.detached(priority: .utility) {
            await WorktreeCreatorHook.updateInstalledScript()
        }
    }

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

func requestedVisualTestAppearance(
    environment: [String: String]
) -> NSAppearance.Name? {
    switch environment["AGENTGIT_VISUAL_TEST_APPEARANCE"]?.lowercased() {
    case "light": .aqua
    case "dark": .darkAqua
    default: nil
    }
}
