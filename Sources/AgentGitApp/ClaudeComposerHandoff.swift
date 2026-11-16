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

    fileprivate static func paste(_ text: String, into composer: AXUIElement, application app: NSRunningApplication, root: AXUIElement) async -> Bool {
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

    fileprivate static func find(
        in root: AXUIElement,
        maximumDepth: Int,
        maximumVisited: Int = 2_000,
        depthFirst: Bool = false,
        matches: (AXUIElement) -> Bool,
        descend: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var visited = 0
        while (depthFirst ? !pending.isEmpty : index < pending.count), visited < maximumVisited {
            let (element, depth) = depthFirst ? pending.removeLast() : pending[index]
            index += 1
            visited += 1
            if matches(element) { return element }
            guard depth < maximumDepth, descend(element),
                  let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] else { continue }
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    fileprivate static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

/// Antigravity 桌面端的会话切换、输入框聚焦与草稿填写（不自动发送）。
@MainActor
enum AntigravityComposerHandoff {
    nonisolated static let bundleIdentifier = "com.google.antigravity"
    nonisolated static let focusURL = URL(string: "antigravity://focus")!

    static func requestAccessIfNeeded() -> Bool {
        ClaudeComposerHandoff.requestAccessIfNeeded()
    }

    /// 异步通过 LaunchServices 打开 `antigravity://focus`，不阻塞主线程，也不重置当前会话路由。
    static func openFocusURL() -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([focusURL], withApplicationAt: appURL, configuration: config, completionHandler: nil)
        return true
    }

    nonisolated static func sessionID(from url: URL) -> String? {
        guard url.scheme == "antigravity", url.host == "conversation" else { return nil }
        let raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: raw)?.uuidString.lowercased()
    }

    nonisolated static func matchesSession(_ url: URL, sessionID: String) -> Bool {
        guard isHubURL(url), url.path.hasPrefix("/c/") else {
            return false
        }
        let target = sessionID.lowercased()
        let rawIDs = String(url.path.dropFirst("/c/".count))
        if rawIDs.lowercased() == target {
            return true
        }
        guard rawIDs.contains("+") else {
            return false
        }
        let panes = rawIDs.split(separator: "+").map { $0.lowercased() }
        guard panes.contains(target) else {
            return false
        }
        let focused = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "focused" })?
            .value?
            .lowercased()
        return (focused ?? panes.first) == target
    }

    nonisolated static func matchesConversationLink(_ url: URL, sessionID: String) -> Bool {
        guard isHubURL(url) else {
            return false
        }
        return url.path.lowercased() == "/c/\(sessionID.lowercased())"
    }

    nonisolated fileprivate static func isHubURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    static func navigate(sessionURL: URL, workspacePath: String? = nil) async -> Bool {
        guard AXIsProcessTrusted(), let sessionID = sessionID(from: sessionURL) else { return false }
        return await AntigravityHubNavigator.shared.navigate(
            sessionID: sessionID,
            workspacePath: workspacePath
        )
    }

    static func fill(_ text: String, sessionURL: URL, workspacePath: String? = nil) async -> Bool {
        guard AXIsProcessTrusted(), let sessionID = sessionID(from: sessionURL) else { return false }
        copyToPasteboard(text)
        let outcome = await AntigravityHubNavigator.shared.fill(
            text: text,
            sessionID: sessionID,
            workspacePath: workspacePath
        )
        if !outcome.filled, !Task.isCancelled {
            AgentGitDiagnostics.shared.record("agent.antigravity.composer", fields: [
                "result": outcome.failureReason,
                "webAreas": outcome.observedWebAreas.joined(separator: ", ")
            ])
        }
        return outcome.filled
    }
}

/// 在独立 `.userInteractive` 队列中执行 Antigravity 会话定位、输入框聚焦与草稿粘贴：
/// - 优先从 `AXWindows` 按 `AXWebArea` 剪枝找本地 Hub（1 步跳过内置浏览器 Tab），`AXWindows` 未就绪时回退坐标命中；
/// - 按 PID 缓存 `(webArea, sidebar)`，剪枝每行按钮子树，支持自动展开折叠侧边栏与工作区分组，兜底 `/history` 列表；
/// - 纯跳转后自动将焦点从侧边栏链接切回底部 `Message input`，`Send to Agent` 则稳定后追加粘贴并把光标移回开头。
private final class AntigravityHubNavigator: @unchecked Sendable {
    static let shared = AntigravityHubNavigator()

    struct FillOutcome: Sendable {
        let filled: Bool
        let failureReason: String
        let observedWebAreas: [String]
    }

    private enum EditorShortcut: CGKeyCode {
        case paste = 9
        case documentEnd = 125
        case documentStart = 126
    }

    private struct CachedHubElements {
        var webArea: AXUIElement
        var sidebar: AXUIElement?
    }

    private struct HubAncestors {
        var webArea: AXUIElement?
        var sidebar: AXUIElement?
        var window: AXUIElement?
    }

    private struct HubScanResult {
        var targetLink: AXUIElement?
        var sidebar: AXUIElement?
        var toggleSidebarButton: AXUIElement?
        var collapsedSectionButton: AXUIElement?
        var conversationLinkCount = 0
    }

    private enum AttemptOutcome {
        case ready(pid: pid_t, webArea: AXUIElement)
        case retry(sawLoadedSidebar: Bool)
    }

    private let workerQueue = DispatchQueue(
        label: "com.sigma.agentgit.antigravity-navigator",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var cachedHubByPID: [pid_t: CachedHubElements] = [:]

    func navigate(sessionID: String, workspacePath: String?) async -> Bool {
        let currentGeneration = nextGeneration()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                workerQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    let result = self.navigateSync(
                        sessionID: sessionID,
                        workspacePath: workspacePath,
                        generation: currentGeneration
                    )
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { [weak self] in
            self?.cancelIfCurrent(generation: currentGeneration)
        }
    }

    func fill(text: String, sessionID: String, workspacePath: String?) async -> FillOutcome {
        let currentGeneration = nextGeneration()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                workerQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(returning: FillOutcome(
                            filled: false,
                            failureReason: "cancelled",
                            observedWebAreas: []
                        ))
                        return
                    }
                    let result = self.fillSync(
                        text: text,
                        sessionID: sessionID,
                        workspacePath: workspacePath,
                        generation: currentGeneration
                    )
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { [weak self] in
            self?.cancelIfCurrent(generation: currentGeneration)
        }
    }

    private func nextGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        generation &+= 1
        return generation
    }

    private func cancelIfCurrent(generation expected: UInt64) {
        stateLock.lock()
        if generation == expected {
            generation &+= 1
        }
        stateLock.unlock()
    }

    private func isCurrent(generation expected: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == expected
    }

    private func cachedElements(for pid: pid_t) -> CachedHubElements? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedHubByPID[pid]
    }

    private func setCachedElements(_ elements: CachedHubElements?, for pid: pid_t) {
        stateLock.lock()
        cachedHubByPID[pid] = elements
        stateLock.unlock()
    }

    private func navigateSync(
        sessionID: String,
        workspacePath: String?,
        generation: UInt64
    ) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let workspaceName = Self.workspaceFolderName(from: workspacePath)
        var didToggleSidebar = false
        var didExpandSection = false
        var stableSidebarMisses = 0
        var observedWebAreas: [String] = []

        for attempt in 0 ..< 80 {
            guard isCurrent(generation: generation) else { return false }
            let justExpandedUI = didToggleSidebar || didExpandSection
            let outcome = trySwitchOrLocateSession(
                sessionID: sessionID,
                expectedWorkspaceName: workspaceName,
                didToggleSidebar: &didToggleSidebar,
                didExpandSection: &didExpandSection,
                observedWebAreas: &observedWebAreas
            )

            switch outcome {
            case let .ready(pid, webArea):
                ensureMessageInputFocused(
                    pid: pid,
                    webArea: webArea,
                    sessionID: sessionID,
                    generation: generation
                )
                return true
            case let .retry(sawLoadedSidebar):
                let expandedThisTurn = !justExpandedUI && (didToggleSidebar || didExpandSection)
                if expandedThisTurn {
                    stableSidebarMisses = 0
                } else if sawLoadedSidebar {
                    stableSidebarMisses += 1
                    if stableSidebarMisses >= 15 {
                        return false
                    }
                }
            }

            Thread.sleep(forTimeInterval: attempt < 20 ? 0.015 : 0.06)
        }
        return false
    }

    private func fillSync(
        text: String,
        sessionID: String,
        workspacePath: String?,
        generation: UInt64
    ) -> FillOutcome {
        guard AXIsProcessTrusted() else {
            return FillOutcome(filled: false, failureReason: "accessibility-untrusted", observedWebAreas: [])
        }
        let workspaceName = Self.workspaceFolderName(from: workspacePath)
        var didToggleSidebar = false
        var didExpandSection = false
        var observedWebAreas: [String] = []
        var foundSessionArea = false
        var didPressSessionLink = false

        let deadline = Date().addingTimeInterval(8.0)
        var attempt = 0
        while Date() < deadline, isCurrent(generation: generation) {
            if !didPressSessionLink {
                let outcome = trySwitchOrLocateSession(
                    sessionID: sessionID,
                    expectedWorkspaceName: workspaceName,
                    didToggleSidebar: &didToggleSidebar,
                    didExpandSection: &didExpandSection,
                    observedWebAreas: &observedWebAreas
                )
                if case .ready = outcome {
                    didPressSessionLink = true
                }
            }

            if let (pid, appElement, webArea) = locateActiveSessionWebArea(
                sessionID: sessionID,
                observedWebAreas: &observedWebAreas
            ) {
                foundSessionArea = true
                let frontmost = Self.boolAttribute(kAXFrontmostAttribute as CFString, of: appElement) == true
                if frontmost, let composer = Self.findMessageInput(in: webArea) {
                    // 确认会话切换后的编辑器节点稳定再粘贴。
                    Thread.sleep(forTimeInterval: 0.06)
                    guard isCurrent(generation: generation) else { break }
                    if let (_, currentAppElement, currentArea) = locateActiveSessionWebArea(
                        sessionID: sessionID,
                        observedWebAreas: &observedWebAreas
                    ),
                       Self.boolAttribute(kAXFrontmostAttribute as CFString, of: currentAppElement) == true,
                       let currentComposer = Self.findMessageInput(in: currentArea),
                       CFEqual(composer, currentComposer),
                       pasteIntoComposer(
                           text: text,
                           composer: currentComposer,
                           appElement: currentAppElement,
                           pid: pid,
                           generation: generation
                       )
                    {
                        return FillOutcome(
                            filled: true,
                            failureReason: "",
                            observedWebAreas: observedWebAreas
                        )
                    }
                }
            }

            Thread.sleep(forTimeInterval: attempt < 25 ? 0.02 : 0.06)
            attempt += 1
        }

        return FillOutcome(
            filled: false,
            failureReason: foundSessionArea ? "prompt-not-found" : "session-area-not-found",
            observedWebAreas: observedWebAreas
        )
    }

    private func locateActiveSessionWebArea(
        sessionID: String,
        observedWebAreas: inout [String]
    ) -> (pid: pid_t, appElement: AXUIElement, webArea: AXUIElement)? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: AntigravityComposerHandoff.bundleIdentifier)
        for app in apps {
            let pid = app.processIdentifier
            let appElement = Self.applicationElement(for: pid)
            if let cached = cachedElements(for: pid),
               Self.stringAttribute(kAXRoleAttribute as CFString, of: cached.webArea) == "AXWebArea",
               Self.isShowingSession(cached.webArea, sessionID: sessionID)
            {
                return (pid, appElement, cached.webArea)
            }
            let windows = Self.windows(of: appElement)
            for root in Self.discoverHubRoots(appElement: appElement, windows: windows, pid: pid) {
                guard let webArea = root.webArea else { continue }
                if let url = Self.elementURL(of: webArea) {
                    let desc = "\(url.host ?? "file")\(url.path)"
                    if !observedWebAreas.contains(desc) {
                        observedWebAreas.append(desc)
                    }
                }
                if Self.isShowingSession(webArea, sessionID: sessionID) {
                    setCachedElements(CachedHubElements(webArea: webArea, sidebar: root.sidebar), for: pid)
                    return (pid, appElement, webArea)
                }
            }
        }
        return nil
    }

    private func pasteIntoComposer(
        text: String,
        composer: AXUIElement,
        appElement: AXUIElement,
        pid: pid_t,
        generation: UInt64
    ) -> Bool {
        guard AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.035)
        guard isCurrent(generation: generation),
              Self.boolAttribute(kAXFrontmostAttribute as CFString, of: appElement) == true,
              Self.isFocusedElement(composer, in: appElement) else {
            return false
        }
        DispatchQueue.main.sync {
            copyToPasteboard(text)
        }
        guard Self.post(.documentEnd, to: pid), Self.post(.paste, to: pid) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.15)
        guard isCurrent(generation: generation),
              Self.boolAttribute(kAXFrontmostAttribute as CFString, of: appElement) == true,
              Self.isFocusedElement(composer, in: appElement) else {
            return false
        }
        var start = CFRange(location: 0, length: 0)
        if let range = AXValueCreate(.cfRange, &start),
           AXUIElementSetAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString, range) == .success {
            return true
        }
        return Self.post(.documentStart, to: pid)
    }

    private func trySwitchOrLocateSession(
        sessionID: String,
        expectedWorkspaceName: String?,
        didToggleSidebar: inout Bool,
        didExpandSection: inout Bool,
        observedWebAreas: inout [String]
    ) -> AttemptOutcome {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: AntigravityComposerHandoff.bundleIdentifier)
        guard !apps.isEmpty else { return .retry(sawLoadedSidebar: false) }

        var sawLoadedSidebar = false
        var toggleCandidate: (button: AXUIElement, window: AXUIElement?)?
        var expandCandidate: AXUIElement?

        for app in apps {
            let pid = app.processIdentifier

            if let cached = cachedElements(for: pid),
               Self.stringAttribute(kAXRoleAttribute as CFString, of: cached.webArea) == "AXWebArea"
            {
                if Self.isShowingSession(cached.webArea, sessionID: sessionID) {
                    return .ready(pid: pid, webArea: cached.webArea)
                }
                if let cachedSidebar = cached.sidebar, Self.isSidebarLandmark(cachedSidebar) {
                    let quickScan = Self.scanSidebar(
                        cachedSidebar,
                        sessionID: sessionID,
                        expectedWorkspaceName: expectedWorkspaceName
                    )
                    if let link = quickScan.targetLink,
                       AXUIElementPerformAction(link, kAXPressAction as CFString) == .success
                    {
                        return .ready(pid: pid, webArea: cached.webArea)
                    }
                }
            } else {
                setCachedElements(nil, for: pid)
            }

            let appElement = Self.applicationElement(for: pid)
            let windows = Self.windows(of: appElement)
            var scannedWebAreas: [AXUIElement] = []

            for root in Self.discoverHubRoots(appElement: appElement, windows: windows, pid: pid) {
                guard let webArea = root.webArea else { continue }
                if scannedWebAreas.contains(where: { CFEqual($0, webArea) }) {
                    continue
                }
                scannedWebAreas.append(webArea)

                if let url = Self.elementURL(of: webArea) {
                    let desc = "\(url.host ?? "file")\(url.path)"
                    if !observedWebAreas.contains(desc) {
                        observedWebAreas.append(desc)
                    }
                }

                if Self.isShowingSession(webArea, sessionID: sessionID) {
                    if let window = root.window {
                        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    }
                    setCachedElements(CachedHubElements(webArea: webArea, sidebar: root.sidebar), for: pid)
                    return .ready(pid: pid, webArea: webArea)
                }

                let scan = Self.scanHubWebArea(
                    webArea,
                    knownSidebar: root.sidebar,
                    sessionID: sessionID,
                    expectedWorkspaceName: expectedWorkspaceName
                )
                setCachedElements(
                    CachedHubElements(webArea: webArea, sidebar: scan.sidebar ?? root.sidebar),
                    for: pid
                )

                if let link = scan.targetLink {
                    if let window = root.window {
                        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    }
                    if AXUIElementPerformAction(link, kAXPressAction as CFString) == .success {
                        return .ready(pid: pid, webArea: webArea)
                    }
                }
                if scan.conversationLinkCount > 0 {
                    sawLoadedSidebar = true
                }
                if expandCandidate == nil, let sectionButton = scan.collapsedSectionButton {
                    expandCandidate = sectionButton
                }
                if toggleCandidate == nil,
                   scan.conversationLinkCount == 0,
                   scan.sidebar == nil,
                   let toggleButton = scan.toggleSidebarButton
                {
                    toggleCandidate = (toggleButton, root.window)
                }
            }
        }

        if !didExpandSection, let sectionButton = expandCandidate {
            if AXUIElementPerformAction(sectionButton, kAXPressAction as CFString) == .success {
                didExpandSection = true
            }
        } else if !didToggleSidebar, let candidate = toggleCandidate {
            if let window = candidate.window {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            if AXUIElementPerformAction(candidate.button, kAXPressAction as CFString) == .success {
                didToggleSidebar = true
            }
        }

        return .retry(sawLoadedSidebar: sawLoadedSidebar)
    }

    private func ensureMessageInputFocused(
        pid: pid_t,
        webArea: AXUIElement,
        sessionID: String,
        generation: UInt64
    ) {
        let appElement = AXUIElementCreateApplication(pid)
        for _ in 0 ..< 30 {
            guard isCurrent(generation: generation) else { return }
            let frontmost = Self.boolAttribute(kAXFrontmostAttribute as CFString, of: appElement) == true
            let routeReady = Self.isShowingSession(webArea, sessionID: sessionID)
            if frontmost, routeReady {
                if !Self.isMessageInputFocused(appElement: appElement),
                   let input = Self.findMessageInput(in: webArea)
                {
                    _ = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
                if Self.isMessageInputFocused(appElement: appElement) {
                    Thread.sleep(forTimeInterval: 0.025)
                    guard isCurrent(generation: generation) else { return }
                    if Self.isMessageInputFocused(appElement: appElement) {
                        return
                    }
                    if let input = Self.findMessageInput(in: webArea) {
                        _ = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    }
                    if Self.isMessageInputFocused(appElement: appElement) {
                        return
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.015)
        }
    }

    private static func applicationElement(for pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        _ = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return element
    }

    private static func discoverHubRoots(
        appElement: AXUIElement,
        windows: [AXUIElement],
        pid: pid_t
    ) -> [HubAncestors] {
        var results: [HubAncestors] = []

        let unminimized = windows.filter { Self.boolAttribute(kAXMinimizedAttribute as CFString, of: $0) != true }
        let orderedWindows = unminimized.isEmpty ? windows : unminimized
        for window in orderedWindows {
            if let hubArea = Self.hubWebArea(in: window) {
                results.append(HubAncestors(webArea: hubArea, sidebar: nil, window: window))
            }
        }
        if !results.isEmpty {
            return results
        }

        for rect in Self.onScreenWindowBounds(pid: pid) {
            let probePoints = [
                CGPoint(x: min(rect.minX + 120, rect.maxX - 16), y: min(rect.minY + 180, rect.maxY - 16)),
                CGPoint(x: min(rect.minX + 24, rect.maxX - 16), y: min(rect.minY + 56, rect.maxY - 16)),
                CGPoint(x: rect.midX, y: min(rect.minY + 48, rect.maxY - 16)),
                CGPoint(x: min(rect.minX + 24, rect.maxX - 16), y: rect.midY)
            ]
            for point in probePoints {
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(
                    appElement,
                    Float(point.x),
                    Float(point.y),
                    &hit
                ) == .success, let hit else {
                    continue
                }
                let ancestors = Self.resolveHubAncestors(from: hit)
                if ancestors.webArea != nil {
                    results.append(ancestors)
                    if ancestors.sidebar != nil {
                        break
                    }
                }
            }
        }

        if results.isEmpty {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused,
               CFGetTypeID(focused) == AXUIElementGetTypeID()
            {
                let element = unsafeDowncast(focused, to: AXUIElement.self)
                let ancestors = Self.resolveHubAncestors(from: element)
                if ancestors.webArea != nil {
                    results.append(ancestors)
                }
            }
        }
        return results
    }

    private static func hubWebArea(in window: AXUIElement) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        var visited = 0

        while index < queue.count, visited < 400 {
            let (element, depth) = queue[index]
            index += 1
            visited += 1

            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element) ?? ""
            if role == "AXWebArea" {
                if Self.isLocalHubWebArea(element) {
                    return element
                }
                continue
            }
            if role == kAXButtonRole as String || role == "AXMenuBar" || role == "AXMenu" {
                continue
            }
            guard depth < 12 else { continue }
            for child in Self.children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func resolveHubAncestors(from start: AXUIElement) -> HubAncestors {
        var result = HubAncestors()
        var fallbackWebArea: AXUIElement?
        var current = start

        for _ in 0 ..< 64 {
            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: current)
            if result.sidebar == nil, Self.isSidebarLandmark(current) {
                result.sidebar = current
            } else if role == "AXWebArea" {
                fallbackWebArea = current
                if Self.isLocalHubWebArea(current) {
                    result.webArea = current
                }
            } else if role == kAXWindowRole as String {
                result.window = current
            }

            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else {
                break
            }
            let next = unsafeDowncast(parent, to: AXUIElement.self)
            if CFEqual(next, current) {
                break
            }
            current = next
        }

        if result.webArea == nil {
            result.webArea = fallbackWebArea
        }
        return result
    }

    private static func scanHubWebArea(
        _ webArea: AXUIElement,
        knownSidebar: AXUIElement?,
        sessionID: String,
        expectedWorkspaceName: String?
    ) -> HubScanResult {
        var result = HubScanResult()
        var sidebar = knownSidebar

        if sidebar == nil {
            var queue: [(element: AXUIElement, depth: Int)] = [(webArea, 0)]
            var index = 0
            var visited = 0
            while index < queue.count, visited < 400 {
                let (element, depth) = queue[index]
                index += 1
                visited += 1

                let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element) ?? ""
                if role == "AXGroup" {
                    if Self.isSidebarLandmark(element) {
                        sidebar = element
                        if result.toggleSidebarButton != nil {
                            break
                        }
                        continue
                    }
                    if Self.isIgnoredHubRegion(element) {
                        continue
                    }
                } else if role == kAXButtonRole as String, result.toggleSidebarButton == nil {
                    let label = Self.stringAttribute(kAXDescriptionAttribute as CFString, of: element)
                        ?? Self.stringAttribute(kAXTitleAttribute as CFString, of: element)
                    if let label, label.hasPrefix("Toggle Sidebar") {
                        result.toggleSidebarButton = element
                        if sidebar != nil {
                            break
                        }
                    }
                    continue
                } else if role != "AXWebArea" {
                    continue
                }

                guard depth < 14 else { continue }
                for child in Self.children(of: element) {
                    queue.append((child, depth + 1))
                }
            }
        }

        result.sidebar = sidebar
        if let sidebar {
            let sidebarScan = Self.scanSidebar(
                sidebar,
                sessionID: sessionID,
                expectedWorkspaceName: expectedWorkspaceName
            )
            result.targetLink = sidebarScan.targetLink
            result.conversationLinkCount = sidebarScan.conversationLinkCount
            result.collapsedSectionButton = sidebarScan.collapsedSectionButton
            if result.targetLink != nil {
                return result
            }
        }

        let fallback = Self.scanNonHubArea(root: webArea, sessionID: sessionID)
        if let link = fallback.targetLink {
            result.targetLink = link
        }
        if fallback.conversationLinkCount > result.conversationLinkCount {
            result.conversationLinkCount = fallback.conversationLinkCount
        }
        if result.toggleSidebarButton == nil {
            result.toggleSidebarButton = fallback.toggleSidebarButton
        }
        return result
    }

    private static func scanSidebar(
        _ sidebar: AXUIElement,
        sessionID: String,
        expectedWorkspaceName: String?
    ) -> HubScanResult {
        var result = HubScanResult(sidebar: sidebar)
        var queue: [AXUIElement] = [sidebar]
        var buttons: [AXUIElement] = []
        var index = 0
        var visited = 0

        while index < queue.count, visited < 2_500 {
            let element = queue[index]
            index += 1
            visited += 1

            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element) ?? ""
            if role == "AXLink" {
                if let url = Self.elementURL(of: element) {
                    if AntigravityComposerHandoff.matchesConversationLink(url, sessionID: sessionID) {
                        result.targetLink = element
                        return result
                    }
                    if AntigravityComposerHandoff.isHubURL(url), url.path.hasPrefix("/c/") {
                        result.conversationLinkCount += 1
                    }
                }
                continue
            }
            if role == kAXButtonRole as String {
                buttons.append(element)
                continue
            }
            if role == "AXPopUpButton" || role == "AXImage" || role == "AXStaticText" || role == "AXCheckBox" {
                continue
            }
            queue.append(contentsOf: Self.children(of: element))
        }

        var fallbackMainHeaderButton: AXUIElement?
        for button in buttons {
            guard Self.boolAttribute("AXExpanded" as CFString, of: button) == false else { continue }
            let label = (Self.stringAttribute(kAXTitleAttribute as CFString, of: button)
                ?? Self.stringAttribute(kAXDescriptionAttribute as CFString, of: button))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let label, !label.isEmpty else { continue }
            if let expectedWorkspaceName,
               label.caseInsensitiveCompare(expectedWorkspaceName) == .orderedSame
            {
                result.collapsedSectionButton = button
                break
            }
            if fallbackMainHeaderButton == nil,
               label == "Conversations" || label == "Workspaces" || label == "Projects"
            {
                fallbackMainHeaderButton = button
            }
        }

        if result.collapsedSectionButton == nil, result.conversationLinkCount == 0 {
            result.collapsedSectionButton = fallbackMainHeaderButton
        }
        return result
    }

    private static func scanNonHubArea(root: AXUIElement, sessionID: String) -> HubScanResult {
        var result = HubScanResult()
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        var visited = 0

        while index < queue.count, visited < 4_000 {
            let (element, depth) = queue[index]
            index += 1
            visited += 1

            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element) ?? ""
            if role == "AXWebArea", !CFEqual(element, root), !Self.isLocalHubWebArea(element) {
                continue
            }
            if role == "AXLink" {
                if let url = Self.elementURL(of: element) {
                    if AntigravityComposerHandoff.matchesConversationLink(url, sessionID: sessionID) {
                        result.targetLink = element
                        return result
                    }
                    if AntigravityComposerHandoff.isHubURL(url), url.path.hasPrefix("/c/") {
                        result.conversationLinkCount += 1
                    }
                }
                continue
            }
            if role == kAXButtonRole as String {
                if result.toggleSidebarButton == nil {
                    let label = Self.stringAttribute(kAXDescriptionAttribute as CFString, of: element)
                        ?? Self.stringAttribute(kAXTitleAttribute as CFString, of: element)
                    if let label, label.hasPrefix("Toggle Sidebar") {
                        result.toggleSidebarButton = element
                    }
                }
                continue
            }
            if role == "AXPopUpButton" || role == "AXImage" || role == "AXStaticText" || role == "AXCheckBox"
                || role == "AXMenuBar" || role == "AXMenu" || role == "AXApplication"
            {
                continue
            }
            if role == "AXGroup", Self.isSidebarLandmark(element) || Self.isIgnoredHubRegion(element) {
                continue
            }
            guard depth < 32 else { continue }
            for child in Self.children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        return result
    }

    private static func findMessageInput(in root: AXUIElement) -> AXUIElement? {
        var stack: [AXUIElement] = [root]
        var visited = 0

        while let element = stack.popLast(), visited < 800 {
            visited += 1
            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: element) ?? ""
            if role == "AXTextArea" || role == "AXComboBox" || role == "AXTextField" {
                if Self.boolAttribute(kAXEnabledAttribute as CFString, of: element) != false,
                   Self.hasLabel("Message input", on: element)
                {
                    return element
                }
                continue
            }
            if role == "AXWebArea", !CFEqual(element, root) {
                continue
            }
            if role == kAXButtonRole as String || role == "AXPopUpButton" || role == "AXImage"
                || role == "AXStaticText" || role == "AXLink" || role == "AXCheckBox"
                || role == "AXList" || role == "AXHeading" || role == "AXMenuBar" || role == "AXMenu"
            {
                continue
            }
            if role == "AXGroup", Self.isIgnoredHubRegion(element) || Self.isSidebarLandmark(element) {
                continue
            }
            stack.append(contentsOf: Self.children(of: element))
        }
        return nil
    }

    private static func isMessageInputFocused(appElement: AXUIElement) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return false
        }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        return Self.hasLabel("Message input", on: element)
    }

    private static func isFocusedElement(_ expected: AXUIElement, in appElement: AXUIElement) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return false
        }
        return CFEqual(focused, expected)
    }

    private static func post(_ shortcut: EditorShortcut, to processID: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.rawValue, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.rawValue, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processID)
        up.postToPid(processID)
        return true
    }

    private static func isSidebarLandmark(_ element: AXUIElement) -> Bool {
        Self.hasLabel("Sidebar", on: element)
            && (Self.stringAttribute(kAXSubroleAttribute as CFString, of: element) == "AXLandmarkNavigation"
                || Self.stringAttribute(kAXRoleAttribute as CFString, of: element) == kAXGroupRole as String)
    }

    private static func isIgnoredHubRegion(_ element: AXUIElement) -> Bool {
        Self.hasLabel("File Viewer", on: element)
            || Self.hasLabel("Notifications", on: element)
            || Self.hasLabel("Typeahead menu", on: element)
    }

    private static func hasLabel(_ expected: String, on element: AXUIElement) -> Bool {
        Self.stringAttribute(kAXDescriptionAttribute as CFString, of: element) == expected
            || Self.stringAttribute(kAXTitleAttribute as CFString, of: element) == expected
    }

    private static func isLocalHubWebArea(_ element: AXUIElement) -> Bool {
        guard let url = Self.elementURL(of: element) else { return false }
        return AntigravityComposerHandoff.isHubURL(url)
    }

    private static func isShowingSession(_ element: AXUIElement, sessionID: String) -> Bool {
        guard let url = Self.elementURL(of: element) else { return false }
        return AntigravityComposerHandoff.matchesSession(url, sessionID: sessionID)
    }

    private static func elementURL(of element: AXUIElement) -> URL? {
        for attr in [kAXURLAttribute as CFString, kAXDocumentAttribute as CFString] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr, &value) == .success,
                  let value
            else {
                continue
            }
            if let url = value as? URL {
                return url
            }
            if let raw = value as? String, let url = URL(string: raw) {
                return url
            }
        }
        return nil
    }

    private static func windows(of appElement: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
           let list = value as? [AXUIElement]
        {
            result = list.filter {
                !CFEqual($0, appElement)
                    && Self.stringAttribute(kAXRoleAttribute as CFString, of: $0) == kAXWindowRole as String
            }
        }
        if result.isEmpty {
            for attr in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
                var single: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, attr, &single) == .success,
                   let element = single,
                   CFGetTypeID(element) == AXUIElementGetTypeID()
                {
                    let axWindow = unsafeDowncast(element, to: AXUIElement.self)
                    if !CFEqual(axWindow, appElement),
                       Self.stringAttribute(kAXRoleAttribute as CFString, of: axWindow) == kAXWindowRole as String
                    {
                        result.append(axWindow)
                        break
                    }
                }
            }
        }
        return result
    }

    private static func onScreenWindowBounds(pid: pid_t) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return windows.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 300,
                  rect.height >= 200
            else {
                return nil
            }
            return rect
        }
    }

    private static func workspaceFolderName(from workspacePath: String?) -> String? {
        guard let raw = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let name = URL(fileURLWithPath: raw).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? nil : name
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else {
            return []
        }
        return children
    }

    private static func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let string = value as? String
        else {
            return nil
        }
        return string
    }

    private static func boolAttribute(_ attribute: CFString, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let boolValue = value as? Bool
        else {
            return nil
        }
        return boolValue
    }
}
