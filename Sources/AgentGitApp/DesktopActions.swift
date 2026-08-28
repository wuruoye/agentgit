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
