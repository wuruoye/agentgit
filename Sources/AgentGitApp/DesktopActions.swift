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
    openCustomApplication(entry, targetURL: targetURL)
}

/// 文件菜单始终打开点中的文件，不使用 worktree 菜单配置的相对路径。
@MainActor
func openFile(_ fileURL: URL, with entry: WorktreeOpenWithEntry, lineNumber: Int? = nil) {
    openCustomApplication(entry, targetURL: fileURL, opensSelectedFile: true, lineNumber: lineNumber)
}

@MainActor
private func openCustomApplication(
    _ entry: WorktreeOpenWithEntry,
    targetURL: URL,
    opensSelectedFile: Bool = false,
    lineNumber: Int? = nil
) {
    guard let applicationURL = entry.applicationURL() else {
        presentOpenWithFailure(
            title: "Couldn’t Open Application",
            message: WorktreeOpenWithError.applicationNotFound(
                entry.applicationName(for: nil)
            ).localizedDescription
        )
        return
    }

    // AS 的命令行入口会把文件交给已打开的所属工程。
    // 直接传文件路径，工程选择由 IDE 处理。
    let bundle = Bundle(url: applicationURL)
    if opensSelectedFile,
       bundle?.bundleIdentifier?.hasPrefix("com.google.android.studio") == true,
       let executableURL = bundle?.executableURL {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = lineNumber.map { ["--line", String(max(1, $0)), targetURL.path] }
            ?? [targetURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor in
                presentOpenWithFailure(
                    title: "Couldn’t Open File",
                    message: "Android Studio couldn’t open “\(targetURL.path)” (exit code \(process.terminationStatus))."
                )
            }
        }
        do {
            try process.run()
        } catch {
            presentOpenWithFailure(title: "Couldn’t Open Application", message: error.localizedDescription)
        }
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
