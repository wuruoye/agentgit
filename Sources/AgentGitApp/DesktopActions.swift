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

/// 文件树里的文件夹交给系统用所选应用打开，和 worktree 菜单一致。
@MainActor
func openFolder(_ folderURL: URL, with entry: WorktreeOpenWithEntry) {
    openCustomApplication(entry, targetURL: folderURL)
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

    let bundle = Bundle(url: applicationURL)
    if opensSelectedFile,
       let launch = EditorFileLaunch(
           bundleIdentifier: bundle?.bundleIdentifier,
           applicationURL: applicationURL,
           executableURL: bundle?.executableURL,
           fileURL: targetURL,
           lineNumber: lineNumber
       ) {
        let applicationName = entry.applicationName(for: applicationURL)
        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor in
                presentOpenWithFailure(
                    title: "Couldn’t Open File",
                    message: "\(applicationName) couldn’t open “\(targetURL.path)” (exit code \(process.terminationStatus))."
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

/// 通过 IDE 自带的命令行入口打开文件。返回 nil 时交给系统打开。
/// - Android Studio 的入口会把文件交给已打开的所属工程，所以选中文件时始终走它，工程选择由 IDE 处理。
/// - 系统打开文件时没法指定行号，VS Code 只在带行号时用 `code --goto 文件:行号`。
///   `vscode://file/…` 链接默认每次都弹确认框，所以不用它。
struct EditorFileLaunch: Equatable {
    let executableURL: URL
    let arguments: [String]

    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    init?(
        bundleIdentifier: String?,
        applicationURL: URL,
        executableURL: URL?,
        fileURL: URL,
        lineNumber: Int?,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) {
        let line = lineNumber.map { String(max(1, $0)) }
        if bundleIdentifier?.hasPrefix("com.google.android.studio") == true, let executableURL {
            self.init(
                executableURL: executableURL,
                arguments: line.map { ["--line", $0, fileURL.path] } ?? [fileURL.path]
            )
            return
        }
        // 正式版的入口叫 code，Insiders 版叫 code-insiders。
        if bundleIdentifier?.hasPrefix("com.microsoft.VSCode") == true,
           let line,
           let cli = ["code", "code-insiders"]
               .map({ applicationURL.appending(path: "Contents/Resources/app/bin/\($0)") })
               .first(where: isExecutable) {
            self.init(executableURL: cli, arguments: ["--goto", "\(fileURL.path):\(line)"])
            return
        }
        return nil
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
