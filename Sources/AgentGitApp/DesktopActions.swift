import AppKit
import Foundation

func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

func openDocument(_ url: URL) {
    NSWorkspace.shared.open(url)
}

func openInTerminal(_ url: URL) {
    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    NSWorkspace.shared.open(
        [url],
        withApplicationAt: terminal,
        configuration: NSWorkspace.OpenConfiguration()
    )
}

func visualStudioCodeApplicationURL() -> URL? {
    NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.microsoft.VSCode"
    )
}

func openInVisualStudioCode(_ url: URL, applicationURL: URL) {
    NSWorkspace.shared.open(
        [url],
        withApplicationAt: applicationURL,
        configuration: NSWorkspace.OpenConfiguration()
    )
}

/// 用自定义应用打开 worktree 里的文件或文件夹。目标或应用找不到时弹窗说明原因。
@MainActor
func openWorktreePath(_ entry: WorktreeOpenWithEntry, worktreeRootURL: URL) {
    let targetURL: URL
    do {
        targetURL = try WorktreeOpenWithPath.resolve(
            entry.relativePath,
            in: worktreeRootURL
        )
    } catch {
        presentOpenWithFailure(title: "Couldn’t Open File or Folder", message: error.localizedDescription)
        return
    }
    guard let applicationURL = entry.applicationURL() else {
        presentOpenWithFailure(
            title: "Couldn’t Open Application",
            message: WorktreeOpenWithError.applicationNotFound(
                entry.applicationName(for: nil)
            ).localizedDescription
        )
        return
    }
    NSWorkspace.shared.open(
        [targetURL],
        withApplicationAt: applicationURL,
        configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
        guard let error else { return }
        let message = error.localizedDescription
        Task { @MainActor in
            presentOpenWithFailure(title: "Couldn’t Open Application", message: message)
        }
    }
}

@MainActor
func presentOpenWithFailure(title: String, message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    if let window = NSApp.keyWindow {
        alert.beginSheetModal(for: window)
    } else {
        alert.runModal()
    }
}
