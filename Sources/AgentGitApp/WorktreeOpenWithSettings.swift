import AgentGitCore
import AppKit
import Foundation
import Observation
import SwiftUI

/// 仓库级的自定义打开方式，出现在 worktree 右键菜单里，所有 worktree 共用。
struct WorktreeOpenWithEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// 菜单里显示的名字，留空时用应用名。
    var name: String
    /// 选择应用时记下的 .app 路径，存在时优先使用。
    var applicationPath: String
    /// 应用被移走或只填了 bundle id 时，用它向系统查找应用。
    var bundleIdentifier: String
    /// 相对 worktree 根目录的文件夹，留空表示根目录。
    var relativePath: String

    init(
        id: UUID = UUID(),
        name: String = "",
        applicationPath: String = "",
        bundleIdentifier: String = "",
        relativePath: String = ""
    ) {
        self.id = id
        self.name = name
        self.applicationPath = applicationPath
        self.bundleIdentifier = bundleIdentifier
        self.relativePath = relativePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, applicationPath, bundleIdentifier, relativePath
    }

    /// 缺字段时用默认值，旧版本或手改过的配置也能读出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        applicationPath = try container.decodeIfPresent(String.self, forKey: .applicationPath) ?? ""
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath) ?? ""
    }

    /// 先用选中的 .app 路径，路径失效再按 bundle id 查找。
    func applicationURL(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        lookUpBundleIdentifier: (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) -> URL? {
        let path = applicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, fileExists(path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? nil : lookUpBundleIdentifier(identifier)
    }

    func applicationName(for applicationURL: URL?) -> String {
        if let applicationURL {
            return Self.displayName(ofApplicationAt: applicationURL)
        }
        let path = applicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? "Application" : identifier
    }

    func menuTitle(applicationURL: URL?) -> String {
        let customName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customName.isEmpty {
            return "Open with \(customName)"
        }
        let applicationName = applicationName(for: applicationURL)
        let folder = (try? WorktreeOpenWithPath.normalize(relativePath))
            ?? relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return folder.isEmpty
            ? "Open with \(applicationName)"
            : "Open \(folder) with \(applicationName)"
    }

    static func displayName(ofApplicationAt url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

enum WorktreeOpenWithError: LocalizedError, Equatable {
    case absolutePath(String)
    case parentReference(String)
    case outsideWorktree(String)
    case missingDirectory(relativePath: String, path: String)
    case notDirectory(relativePath: String, path: String)
    case applicationNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .absolutePath(path):
            "“\(path)” is an absolute path. Enter a folder relative to the worktree root, such as Sources/App."
        case let .parentReference(path):
            "“\(path)” uses “..”. The folder must stay inside the worktree."
        case let .outsideWorktree(path):
            "“\(path)” points outside the worktree through a symbolic link."
        case let .missingDirectory(relativePath, path):
            "The folder “\(relativePath)” doesn’t exist in this worktree.\n\(path)"
        case let .notDirectory(relativePath, path):
            "“\(relativePath)” is a file, not a folder.\n\(path)"
        case let .applicationNotFound(name):
            "“\(name)” isn’t installed or can’t be found. Choose the application again in Settings."
        }
    }
}

/// 自定义打开方式的相对目录：先按字面规范化，打开前再按真实路径确认没有跳出 worktree。
enum WorktreeOpenWithPath {
    /// 去掉空白、多余的斜杠和 `.`，空字符串表示根目录；拒绝绝对路径和 `..`。
    static func normalize(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            throw WorktreeOpenWithError.absolutePath(trimmed)
        }
        var components: [Substring] = []
        for component in trimmed.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                throw WorktreeOpenWithError.parentReference(trimmed)
            default:
                components.append(component)
            }
        }
        return components.joined(separator: "/")
    }

    /// 返回要打开的目录。目录必须存在，解析符号链接后仍在 worktree 内。
    static func resolveDirectory(_ rawPath: String, in worktreeRootURL: URL) throws -> URL {
        let relativePath = try normalize(rawPath)
        let rootURL = worktreeRootURL.standardizedFileURL
        let directoryURL = relativePath.isEmpty
            ? rootURL
            : rootURL.appending(path: relativePath, directoryHint: .isDirectory)
        let displayPath = relativePath.isEmpty ? "." : relativePath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            throw WorktreeOpenWithError.missingDirectory(relativePath: displayPath, path: directoryURL.path)
        }
        guard isDirectory.boolValue else {
            throw WorktreeOpenWithError.notDirectory(relativePath: displayPath, path: directoryURL.path)
        }
        guard let rootPath = canonicalPath(rootURL.path),
              let directoryPath = canonicalPath(directoryURL.path),
              isPath(directoryPath, inside: rootPath) else {
            throw WorktreeOpenWithError.outsideWorktree(displayPath)
        }
        return directoryURL
    }

    /// 把设置里选中的文件夹换算成相对路径。worktree 互相嵌套时取最近的一层。
    static func relativePath(of directoryURL: URL, inAnyOf worktreeRootURLs: [URL]) -> String? {
        let directoryPath = canonicalPath(directoryURL.path) ?? directoryURL.standardizedFileURL.path
        return worktreeRootURLs.compactMap { rootURL -> String? in
            let rootPath = canonicalPath(rootURL.path) ?? rootURL.standardizedFileURL.path
            guard isPath(directoryPath, inside: rootPath) else { return nil }
            return String(directoryPath.dropFirst(rootPath.count).drop { $0 == "/" })
        }
        .min { $0.count < $1.count }
    }

    private static func isPath(_ path: String, inside rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

@MainActor
@Observable
final class WorktreeOpenWithSettings {
    private static let persistenceKey = "agentgit.open-with-entries-by-project"
    private let defaults: UserDefaults
    private var entriesByProjectID: [GitProject.ID: [WorktreeOpenWithEntry]]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        entriesByProjectID = defaults.data(forKey: Self.persistenceKey).map(Self.decode) ?? [:]
    }

    func entries(for projectID: GitProject.ID) -> [WorktreeOpenWithEntry] {
        entriesByProjectID[projectID] ?? []
    }

    func append(_ entry: WorktreeOpenWithEntry, for projectID: GitProject.ID) {
        setEntries(entries(for: projectID) + [entry], for: projectID)
    }

    func update(_ entry: WorktreeOpenWithEntry, for projectID: GitProject.ID) {
        var entries = entries(for: projectID)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }),
              entries[index] != entry else { return }
        entries[index] = entry
        setEntries(entries, for: projectID)
    }

    func remove(id: WorktreeOpenWithEntry.ID, for projectID: GitProject.ID) {
        setEntries(entries(for: projectID).filter { $0.id != id }, for: projectID)
    }

    /// 项目解析为主 checkout 时，配置跟随同一仓库的项目 ID。
    func moveEntries(from originalID: GitProject.ID, to resolvedID: GitProject.ID) {
        guard originalID != resolvedID, let entries = entriesByProjectID[originalID] else { return }
        if entriesByProjectID[resolvedID] == nil {
            setEntries(entries, for: resolvedID)
        }
        setEntries([], for: originalID)
    }

    private func setEntries(_ entries: [WorktreeOpenWithEntry], for projectID: GitProject.ID) {
        if entries.isEmpty {
            entriesByProjectID.removeValue(forKey: projectID)
        } else {
            entriesByProjectID[projectID] = entries
        }
        if let data = Self.encode(entriesByProjectID) {
            defaults.set(data, forKey: Self.persistenceKey)
        }
    }

    nonisolated static func encode(_ entriesByProjectID: [GitProject.ID: [WorktreeOpenWithEntry]]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(entriesByProjectID)
    }

    /// 配置读不出来时当作没有配置，不影响其他设置。
    nonisolated static func decode(_ data: Data) -> [GitProject.ID: [WorktreeOpenWithEntry]] {
        (try? JSONDecoder().decode([GitProject.ID: [WorktreeOpenWithEntry]].self, from: data)) ?? [:]
    }
}

/// worktree 右键菜单里的自定义打开项。找不到应用时保留菜单项并置灰。
struct WorktreeOpenWithMenuItems: View {
    let entries: [WorktreeOpenWithEntry]
    let worktreeRootURL: URL

    var body: some View {
        ForEach(entries) { entry in
            let applicationURL = entry.applicationURL()
            Button(entry.menuTitle(applicationURL: applicationURL)) {
                openWorktreeFolder(entry, worktreeRootURL: worktreeRootURL)
            }
            .disabled(applicationURL == nil)
        }
    }
}
