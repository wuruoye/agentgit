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

func openInTerminal(_ url: URL) {
    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    NSWorkspace.shared.open(
        [url],
        withApplicationAt: terminal,
        configuration: NSWorkspace.OpenConfiguration()
    )
}
