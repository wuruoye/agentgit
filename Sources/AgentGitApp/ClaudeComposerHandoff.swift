import AppKit
import AgentGitCore
import ApplicationServices
import CoreGraphics
import Foundation

/// 通过目标会话的无障碍输入框填写草稿，不发送消息。
@MainActor
enum ClaudeComposerHandoff {
    private enum EditorShortcut: CGKeyCode {
        case paste = 9
        case documentEnd = 125
        case documentStart = 126
    }

    static func requestAccessIfNeeded() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func activateExistingSession(_ sessionURL: URL) -> Bool {
        guard AXIsProcessTrusted(), let sessionID = sessionID(from: sessionURL),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else {
            return false
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        guard let value = attribute(kAXFocusedWindowAttribute, of: root) ?? attribute(kAXMainWindowAttribute, of: root),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        guard sessionWebArea(in: window, sessionID: sessionID).element != nil else { return false }
        return app.activate(options: [])
    }

    static func fill(_ text: String, sessionURL: URL) async -> Bool {
        guard AXIsProcessTrusted(), let sessionID = sessionID(from: sessionURL) else { return false }
        let deadline = ContinuousClock.now + .seconds(8)
        var observedWebAreas: [String] = []
        var foundSessionArea = false
        while ContinuousClock.now < deadline, !Task.isCancelled {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.anthropic.claudefordesktop"
            }) else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.2)
            _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            let lookup = sessionWebArea(in: root, sessionID: sessionID)
            observedWebAreas = lookup.webAreas
            foundSessionArea = foundSessionArea || lookup.element != nil
            if let area = lookup.element,
               let composer = prompt(in: area), app.isActive {
                // 会话跳转会重建编辑器；确认同一个输入框稳定后再粘贴。
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return false }
                guard let currentArea = sessionWebArea(in: root, sessionID: sessionID).element,
                      let currentComposer = prompt(in: currentArea), CFEqual(composer, currentComposer) else { continue }
                return await paste(text, into: composer, application: app, root: root)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        AgentGitDiagnostics.shared.record("agent.claude.composer", fields: [
            "result": foundSessionArea ? "prompt-not-found" : "session-area-not-found",
            "webAreas": observedWebAreas.joined(separator: ", ")
        ])
        return false
    }

    static func sessionID(from url: URL) -> String? {
        guard url.scheme == "claude" else { return nil }
        if url.host == "code", url.path == "/continue" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "session" })?.value
        }
        return url.host == "claude.ai" ? url.lastPathComponent : nil
    }

    static func matchesSession(_ url: URL, sessionID: String) -> Bool {
        url.host == "claude.ai" && url.path == "/epitaxy/\(sessionID)"
    }

    private static func paste(_ text: String, into composer: AXUIElement, application app: NSRunningApplication, root: AXUIElement) async -> Bool {
        guard app.isActive,
              AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return false }
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled, app.isActive,
              let focused = attribute(kAXFocusedUIElementAttribute, of: root), CFEqual(focused, composer) else { return false }
        // 格式由草稿生成处负责；保留已有草稿，原样粘贴一次。
        copyToPasteboard(text)
        guard post(.documentEnd, to: app.processIdentifier), post(.paste, to: app.processIdentifier) else { return false }
        try? await Task.sleep(for: .milliseconds(200))
        return moveCaretToStart(in: composer, application: app, root: root)
    }

    private static func moveCaretToStart(
        in composer: AXUIElement,
        application app: NSRunningApplication,
        root: AXUIElement
    ) -> Bool {
        guard !Task.isCancelled, app.isActive,
              let focused = attribute(kAXFocusedUIElementAttribute, of: root), CFEqual(focused, composer) else { return false }
        return setCaretToStart(in: composer, processID: app.processIdentifier)
    }

    private static func setCaretToStart(in composer: AXUIElement, processID: pid_t) -> Bool {
        var start = CFRange(location: 0, length: 0)
        if let range = AXValueCreate(.cfRange, &start),
           AXUIElementSetAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString, range) == .success {
            return true
        }
        return post(.documentStart, to: processID)
    }

    private static func post(_ shortcut: EditorShortcut, to processID: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.rawValue, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.rawValue, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processID)
        up.postToPid(processID)
        return true
    }

    private static func sessionWebArea(in root: AXUIElement, sessionID: String) -> (element: AXUIElement?, webAreas: [String]) {
        var webAreas: [String] = []
        let result = find(in: root, maximumDepth: 12, matches: { element in
            guard attribute(kAXRoleAttribute, of: element) as? String == "AXWebArea" else { return false }
            for name in [kAXURLAttribute, kAXDocumentAttribute] {
                guard let rawURL = attribute(name, of: element) else { continue }
                let url = (rawURL as? URL) ?? (rawURL as? String).flatMap { raw in
                    URL(string: raw.hasPrefix("claude.ai/") ? "https://" + raw : raw)
                }
                if let url {
                    webAreas.append("\(url.host ?? "file")\(url.path)")
                    if matchesSession(url, sessionID: sessionID) { return true }
                }
            }
            return false
        }, descend: { _ in true })
        return (result, webAreas)
    }

    private static func prompt(in area: AXUIElement) -> AXUIElement? {
        find(in: area, maximumDepth: 30, depthFirst: true, matches: { element in
            let role = attribute(kAXRoleAttribute, of: element) as? String
            guard role == kAXTextAreaRole || role == kAXTextFieldRole,
                  attribute(kAXEnabledAttribute, of: element) as? Bool != false else { return false }
            return [kAXDescriptionAttribute, kAXTitleAttribute].contains {
                attribute($0, of: element) as? String == "Prompt"
            }
        }, descend: { element in
            // 聊天记录、侧栏和代码对比都不含输入框。
            ![kAXDescriptionAttribute, kAXTitleAttribute].contains {
                guard let label = attribute($0, of: element) as? String else { return false }
                return ["Chat messages", "Changes", "Sidebar"].contains(label)
            }
        })
    }

    private static func find(
        in root: AXUIElement,
        maximumDepth: Int,
        depthFirst: Bool = false,
        matches: (AXUIElement) -> Bool,
        descend: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while (depthFirst ? !pending.isEmpty : index < pending.count), index < 2_000 {
            let (element, depth) = depthFirst ? pending.removeLast() : pending[index]
            index += 1
            if matches(element) { return element }
            guard depth < maximumDepth, descend(element),
                  let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] else { continue }
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
