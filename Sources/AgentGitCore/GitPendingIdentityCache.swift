import CryptoKit
import Darwin
import Foundation

struct GitPendingIdentityMetadata: Sendable {
    let headOID: String?
    let configuration: String
    let definesDefaultFunctionNames: Bool
    let attributes: [String: [String]]
}

/// 同时核对纳秒时间、inode 和设备号，避免同路径替换、原位写入或权限变更沿用旧哈希。
private struct GitPendingFileStat: Hashable, Sendable {
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let inode: UInt64
    let device: Int32
    let mode: UInt16

    init(_ value: stat) {
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        inode = value.st_ino
        device = value.st_dev
        mode = value.st_mode
    }

    var type: mode_t { mode & S_IFMT }

    /// 目录只核对还是不是同一个目录：git status 每次在 .git 里建删 index.lock，都会改目录时间。
    var directoryStamp: Self {
        guard type == S_IFDIR else { return self }
        var value = stat()
        value.st_ino = inode
        value.st_dev = device
        value.st_mode = mode
        return Self(value)
    }

    var identity: String {
        "stat \(device) \(inode) \(mode) \(size) \(modifiedSeconds):\(modifiedNanoseconds) \(changedSeconds):\(changedNanoseconds)"
    }

    static func read(_ url: URL, followsLink: Bool = false) throws -> Self? {
        var value = stat()
        let result = fstatat(AT_FDCWD, url.path, &value, followsLink ? 0 : AT_SYMLINK_NOFOLLOW)
        if result == 0 { return Self(value) }
        let error = errno
        if error == ENOENT || error == ENOTDIR { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
    }

    static func read(_ descriptor: Int32) throws -> Self {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Self(value)
    }
}

private struct GitPendingSourceStamp: Hashable, Sendable {
    let path: String
    let node: GitPendingFileStat?
    let target: GitPendingFileStat?

    init(_ url: URL) throws {
        path = url.standardizedFileURL.path
        node = try GitPendingFileStat.read(url)?.directoryStamp
        target = node?.type == S_IFLNK ? try GitPendingFileStat.read(url, followsLink: true)?.directoryStamp : nil
    }

    var effectiveType: mode_t? { (target ?? node)?.type }
}

actor GitPendingIdentityCache {
    struct FileContent: Sendable {
        let value: String?
        let bytesRead: Int
    }

    private struct FileEntry {
        let stamp: GitPendingFileStat
        let value: String
    }

    private struct SmallFileEntry {
        let stamp: GitPendingSourceStamp
        let value: Data
    }

    private struct Directories {
        let git: URL
        let common: URL
        let sources: [URL]
        let stamps: [GitPendingSourceStamp]
    }

    private struct ConfigurationEntry {
        let sources: [URL]
        let stamps: [GitPendingSourceStamp]
        let digest: String
        let version: Data
        let definesDefaultFunctionNames: Bool
        let attributeFile: URL
    }

    private struct VersionEntry {
        let stamps: [GitPendingSourceStamp]
        let value: Data
    }

    private struct AttributesEntry {
        let configuration: String
        let stamps: [GitPendingSourceStamp]
        let value: [String]
    }

    private struct HeadEntry {
        let stamps: [GitPendingSourceStamp]
        let oid: String?
    }

    private struct IndexObjectsEntry {
        let stamp: GitPendingSourceStamp
        var objects: [String: String] = [:]
        var absent: Set<String> = []
    }

    private struct TreeObjectsEntry {
        var objects: [String: String] = [:]
        var absent: Set<String> = []
    }

    private struct UpstreamEntry {
        let stamps: [GitPendingSourceStamp]
        let oid: String
    }

    private var fileContents: [String: FileEntry] = [:]
    private var smallFiles: [String: SmallFileEntry] = [:]
    private var configurations: [String: ConfigurationEntry] = [:]
    private var versions: [String: VersionEntry] = [:]
    private var attributes: [String: AttributesEntry] = [:]
    private var heads: [String: HeadEntry] = [:]
    private var indexObjects: [String: IndexObjectsEntry] = [:]
    private var treeObjects: [String: TreeObjectsEntry] = [:]
    private var upstreams: [String: UpstreamEntry] = [:]

    func gitDirectories(at root: URL) throws -> (gitDirectory: URL, commonGitDirectory: URL) {
        let directories = try repositoryDirectories(at: root)
        return (directories.git, directories.common)
    }

    /// status 前后核对 index、HEAD 和配置来源，过程中有变化就不复用刷新结果。
    func refreshMetadataStamp(reader: GitPendingIdentityReader) async throws -> String? {
        guard GitCommandRunner.baseEnvironment["GIT_ATTR_SOURCE"] == nil,
              GitCommandRunner.baseEnvironment["GIT_WORK_TREE"] == nil else { return nil }
        let directories = try repositoryDirectories(at: reader.rootURL)
        guard let configuration = try await configuration(reader: reader, directories: directories) else { return nil }
        let sources = try refreshMetadataSources(reader: reader, directories: directories, configuration: configuration)
        let stamps = try snapshot(sources)
        guard directories.stamps == (try snapshot(directories.sources)),
              configuration.stamps == (try snapshot(configuration.sources)) else { return nil }
        return stampIdentity(stamps)
    }

    /// 只读 stat；目录和子模块的内部变化无法用一个目录的 stat 表示，交给调用方继续验证。
    func refreshRevision(
        reader: GitPendingIdentityReader, paths: [String], metadataStamp: String
    ) async throws -> String? {
        let directories = try repositoryDirectories(at: reader.rootURL)
        guard let configuration = try await configuration(reader: reader, directories: directories) else { return nil }
        let metadataSources = try refreshMetadataSources(reader: reader, directories: directories, configuration: configuration)
        let metadataStamps = try snapshot(metadataSources)
        guard stampIdentity(metadataStamps) == metadataStamp else { return nil }
        var sources = metadataSources
        let root = reader.rootURL.standardizedFileURL
        for path in paths {
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { return nil }
            let stamp = try GitPendingSourceStamp(url)
            if let type = stamp.effectiveType, type != S_IFREG && type != S_IFLNK { return nil }
            sources.append(url)
            var directory = url.deletingLastPathComponent()
            while true {
                sources.append(directory.appendingPathComponent(".gitattributes"))
                if directory == root { break }
                directory.deleteLastPathComponent()
            }
        }
        let before = try snapshot(sources)
        guard before == (try snapshot(sources)),
              metadataStamps == (try snapshot(metadataSources)),
              configuration.stamps == (try snapshot(configuration.sources)) else { return nil }
        return stampIdentity(before)
    }

    func upstreamOID(reader: GitPendingIdentityReader, upstreamRef: String) async throws -> String {
        let directories = try repositoryDirectories(at: reader.rootURL)
        guard let configuration = try await configuration(reader: reader, directories: directories) else {
            return String(decoding: try await reader.run(["rev-parse", "@{upstream}^{commit}"]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var sources = try headSources(directories) + configuration.sources
        let candidates = upstreamRef.hasPrefix("refs/") ? [upstreamRef] : [
            "refs/heads/\(upstreamRef)", "refs/remotes/\(upstreamRef)",
            "refs/remotes/\(upstreamRef)/HEAD", "refs/tags/\(upstreamRef)", "refs/\(upstreamRef)"
        ]
        for reference in candidates {
            sources += try referenceSources(reference, directories: directories)
        }
        let before = try snapshot(sources)
        let key = reader.rootURL.path + "\0" + upstreamRef
        if let entry = upstreams[key], entry.stamps == before { return entry.oid }
        let oid = String(decoding: try await reader.run(["rev-parse", "@{upstream}^{commit}"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if before == (try snapshot(sources)) {
            if upstreams.count >= 512, upstreams[key] == nil { upstreams.removeAll(keepingCapacity: true) }
            upstreams[key] = UpstreamEntry(stamps: before, oid: oid)
        }
        return oid
    }

    private func refreshMetadataSources(
        reader: GitPendingIdentityReader, directories: Directories, configuration: ConfigurationEntry
    ) throws -> [URL] {
        let index = GitCommandRunner.baseEnvironment["GIT_INDEX_FILE"].map {
            resolve($0, relativeTo: reader.rootURL)
        } ?? directories.git.appendingPathComponent("index")
        return unique(try headSources(directories) + configuration.sources + [
            index, configuration.attributeFile,
            directories.common.appendingPathComponent("info/attributes"),
            reader.rootURL.appendingPathComponent(".gitattributes"), reader.runner.executableURL
        ] + systemSources(named: "gitattributes", executable: reader.runner.executableURL))
    }

    private func stampIdentity(_ stamps: [GitPendingSourceStamp]) -> String {
        var data = Data()
        for stamp in stamps {
            data.append(Data(stamp.path.utf8))
            data.append(0)
            data.append(Data((stamp.node?.identity ?? "absent").utf8))
            data.append(0)
            data.append(Data((stamp.target?.identity ?? "absent").utf8))
            data.append(0)
        }
        return GitPendingIdentityReader.digest(data)
    }

    func fileContent(at url: URL, maximumBytes: Int) throws -> FileContent {
        try Task.checkCancellation()
        guard let before = try GitPendingFileStat.read(url) else {
            return FileContent(value: "absent", bytesRead: 0)
        }
        if let cached = fileContents[url.path], cached.stamp == before {
            return FileContent(value: cached.value, bytesRead: 0)
        }
        var bytesRead = 0
        var content: String?
        do {
            if before.type == S_IFLNK {
                content = "symlink " + GitPendingIdentityReader.digest(
                    Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
                )
            } else if before.type == S_IFREG,
                      before.size <= 8 * 1_024 * 1_024, before.size <= maximumBytes {
                let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
                guard descriptor >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                guard try GitPendingFileStat.read(descriptor) == before else {
                    return FileContent(value: nil, bytesRead: 0)
                }
                var hash = Insecure.SHA1()
                while let data = try handle.read(upToCount: min(64 * 1_024, maximumBytes - bytesRead + 1)), !data.isEmpty {
                    try Task.checkCancellation()
                    bytesRead += data.count
                    guard bytesRead <= before.size, bytesRead <= maximumBytes else {
                        return FileContent(value: nil, bytesRead: bytesRead)
                    }
                    hash.update(data: data)
                }
                guard bytesRead == before.size, try GitPendingFileStat.read(descriptor) == before else {
                    return FileContent(value: nil, bytesRead: bytesRead)
                }
                content = "file \(before.mode & 0o111) "
                    + hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 不能读取的文件仍可通过稳定的 stat 区分，读取期间变化的文件不生成身份。
        }
        guard try GitPendingFileStat.read(url) == before else {
            return FileContent(value: nil, bytesRead: bytesRead)
        }
        if let content {
            if fileContents.count >= 8_192, fileContents[url.path] == nil {
                fileContents.removeAll(keepingCapacity: true)
            }
            fileContents[url.path] = FileEntry(stamp: before, value: content)
        }
        let value = content ?? ([S_IFREG, S_IFLNK].contains(before.type) ? before.identity : nil)
        return FileContent(value: value, bytesRead: bytesRead)
    }

    func metadata(
        reader: GitPendingIdentityReader, paths: [String], needsHead: Bool, isUnborn: Bool
    ) async throws -> GitPendingIdentityMetadata? {
        let directories = try repositoryDirectories(at: reader.rootURL)
        guard let configuration = try await configuration(reader: reader, directories: directories),
              let values = try await attributeValues(
                reader: reader, paths: paths, directories: directories, configuration: configuration
              ) else { return nil }
        var headOID: String?
        if needsHead {
            guard let entry = try await head(reader: reader, directories: directories, isUnborn: isUnborn)
            else { return nil }
            headOID = entry.oid
        }
        guard directories.stamps == (try snapshot(directories.sources)),
              configuration.stamps == (try snapshot(configuration.sources)) else { return nil }
        return GitPendingIdentityMetadata(
            headOID: headOID, configuration: configuration.digest,
            definesDefaultFunctionNames: configuration.definesDefaultFunctionNames, attributes: values
        )
    }

    /// index 文件没被替换就沿用上次查到的对象；HEAD 指向的 tree 不会变，按提交记住。
    func objects(
        reader: GitPendingIdentityReader, paths: [String], headOID: String?
    ) async throws -> (index: [String: String], head: [String: String])? {
        let directories = try repositoryDirectories(at: reader.rootURL)
        let indexURL = GitCommandRunner.baseEnvironment["GIT_INDEX_FILE"].map {
            resolve($0, relativeTo: reader.rootURL)
        } ?? directories.git.appendingPathComponent("index")
        let before = try GitPendingSourceStamp(indexURL)
        let rootKey = reader.rootURL.standardizedFileURL.path
        var index = indexObjects[rootKey].flatMap { $0.stamp == before ? $0 : nil }
            ?? IndexObjectsEntry(stamp: before)
        let missingIndex = paths.filter { index.objects[$0] == nil && !index.absent.contains($0) }
        for batch in GitPendingIdentityReader.pathBatches(missingIndex) {
            try Task.checkCancellation()
            let loaded = try GitPendingIdentityReader.objects(
                try await reader.run(["ls-files", "--stage", "-z", "--"] + batch), index: true
            )
            for path in batch {
                if let object = loaded[path] { index.objects[path] = object } else { index.absent.insert(path) }
            }
        }
        guard before == (try GitPendingSourceStamp(indexURL)) else { return nil }
        if !missingIndex.isEmpty {
            if indexObjects.count >= 128, indexObjects[rootKey] == nil { indexObjects.removeAll(keepingCapacity: true) }
            if index.objects.count + index.absent.count > 65_536 { index = IndexObjectsEntry(stamp: before) }
            indexObjects[rootKey] = index
        }
        var head: [String: String] = [:]
        if let headOID {
            let treeKey = rootKey + "\0" + headOID
            var tree = treeObjects[treeKey] ?? TreeObjectsEntry()
            let missingTree = paths.filter { tree.objects[$0] == nil && !tree.absent.contains($0) }
            for batch in GitPendingIdentityReader.pathBatches(missingTree) {
                try Task.checkCancellation()
                let loaded = try GitPendingIdentityReader.objects(
                    try await reader.run(["ls-tree", "-z", headOID, "--"] + batch), index: false
                )
                for path in batch {
                    if let object = loaded[path] { tree.objects[path] = object } else { tree.absent.insert(path) }
                }
            }
            if !missingTree.isEmpty {
                if treeObjects.count >= 128, treeObjects[treeKey] == nil { treeObjects.removeAll(keepingCapacity: true) }
                treeObjects[treeKey] = tree.objects.count + tree.absent.count > 65_536 ? nil : tree
            }
            head = paths.reduce(into: [:]) { result, path in result[path] = tree.objects[path] }
        }
        return (paths.reduce(into: [:]) { result, path in result[path] = index.objects[path] }, head)
    }

    private func repositoryDirectories(at root: URL) throws -> Directories {
        let environment = GitCommandRunner.baseEnvironment
        let marker = root.appendingPathComponent(".git")
        let markerBefore = try GitPendingSourceStamp(marker)
        let git: URL
        if let override = environment["GIT_DIR"] {
            git = resolve(override, relativeTo: root)
        } else if markerBefore.effectiveType == S_IFDIR {
            git = marker
        } else {
            let value = String(decoding: try smallFile(marker), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("gitdir: ") else { throw CocoaError(.fileReadCorruptFile) }
            git = resolve(String(value.dropFirst(8)), relativeTo: root)
        }
        let commonMarker = git.appendingPathComponent("commondir")
        let commonBefore = try GitPendingSourceStamp(commonMarker)
        let common: URL
        if let override = environment["GIT_COMMON_DIR"] {
            common = resolve(override, relativeTo: root)
        } else if commonBefore.node != nil {
            common = resolve(
                String(decoding: try smallFile(commonMarker), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: git
            )
        } else {
            common = git
        }
        let sources = unique([marker, commonMarker])
        let stamps = try snapshot(sources)
        guard stamps == [markerBefore, commonBefore].sorted(by: { $0.path < $1.path }) else {
            throw CocoaError(.fileReadUnknown)
        }
        return Directories(git: git, common: common, sources: sources, stamps: stamps)
    }

    private func configuration(
        reader: GitPendingIdentityReader, directories: Directories
    ) async throws -> ConfigurationEntry? {
        guard let version = try await gitVersion(reader: reader) else { return nil }
        let root = reader.rootURL
        let environment = GitCommandRunner.baseEnvironment
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let xdg = resolve(environment["XDG_CONFIG_HOME"] ?? home.appendingPathComponent(".config").path, relativeTo: root)
        var sources = directories.sources + [
            directories.common.appendingPathComponent("config"),
            directories.git.appendingPathComponent("config.worktree"),
            directories.git.appendingPathComponent("HEAD"),
            home.appendingPathComponent(".gitconfig"), xdg.appendingPathComponent("git/config")
        ] + systemSources(named: "gitconfig", executable: reader.runner.executableURL)
        for name in ["GIT_CONFIG_SYSTEM", "GIT_CONFIG_GLOBAL"] {
            if let value = environment[name] { sources.append(resolve(value, relativeTo: root)) }
        }
        let previous = configurations[root.path]
        sources = unique(sources + (previous?.sources ?? []))
        var before = try snapshot(sources)
        if let previous, previous.stamps == before, previous.version == version {
            return previous
        }
        // 首次发现 include 来源后再读一次，把所有来源的前后 stat 一起核对。
        for _ in 0..<3 {
            try Task.checkCancellation()
            let data = try await reader.run(["config", "--null", "--show-origin", "--list"])
            let fields = data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            guard fields.count.isMultiple(of: 2) else { throw CocoaError(.fileReadCorruptFile) }
            let strings = fields.map { String(decoding: $0, as: UTF8.self) }
            var discovered = sources
            var relevant = Data()
            var definesDefaultFunctionNames = false
            var attributeFile = xdg.appendingPathComponent("git/attributes")
            for offset in stride(from: 0, to: strings.count, by: 2) {
                let origin = strings[offset]
                let record = strings[offset + 1]
                let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0]).lowercased()
                let value = parts.count > 1 ? String(parts[1]) : ""
                let source = origin.hasPrefix("file:") ? resolve(String(origin.dropFirst(5)), relativeTo: root) : nil
                if let source { discovered.append(source) }
                if key == "include.path" || (key.hasPrefix("includeif.") && key.hasSuffix(".path")) {
                    discovered.append(resolve(value, relativeTo: source?.deletingLastPathComponent() ?? root))
                }
                if key.hasPrefix("diff.") || key.hasPrefix("filter.")
                    || ["core.autocrlf", "core.eol", "core.safecrlf", "core.filemode", "core.symlinks", "core.attributesfile"].contains(key) {
                    relevant.append(Data(record.utf8))
                    relevant.append(0)
                }
                // 没有 diff 属性的文件会用名为 default 的驱动，它的 funcname 可以在配置里改。
                if key == "diff.default.xfuncname" || key == "diff.default.funcname" {
                    definesDefaultFunctionNames = true
                }
                if key == "core.attributesfile" { attributeFile = resolve(value, relativeTo: root) }
            }
            let expanded = unique(discovered)
            let after = try snapshot(expanded)
            if expanded == sources, before == after {
                relevant.append(version)
                let entry = ConfigurationEntry(
                    sources: expanded, stamps: after, digest: GitPendingIdentityReader.digest(relevant), version: version,
                    definesDefaultFunctionNames: definesDefaultFunctionNames, attributeFile: attributeFile
                )
                if configurations.count >= 128, previous == nil { configurations.removeAll(keepingCapacity: true) }
                configurations[root.path] = entry
                return entry
            }
            sources = expanded
            before = after
        }
        return nil
    }

    private func gitVersion(reader: GitPendingIdentityReader) async throws -> Data? {
        var sources = [reader.runner.executableURL]
        if reader.runner.executableURL.path == "/usr/bin/git" {
            let selected = URL(fileURLWithPath: "/var/db/xcode_select_link")
            sources.append(selected)
            sources.append(URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/git"))
            if let developer = GitCommandRunner.baseEnvironment["DEVELOPER_DIR"] {
                sources.append(URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/git"))
            } else if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: selected.path) {
                sources.append(resolve(target, relativeTo: selected.deletingLastPathComponent()).appendingPathComponent("usr/bin/git"))
            }
        }
        let before = try snapshot(sources)
        if let entry = versions[reader.runner.executableURL.path], entry.stamps == before { return entry.value }
        let value = try await reader.run(["--version"])
        guard before == (try snapshot(sources)) else { return nil }
        versions[reader.runner.executableURL.path] = VersionEntry(stamps: before, value: value)
        return value
    }

    private func attributeValues(
        reader: GitPendingIdentityReader, paths: [String], directories: Directories,
        configuration: ConfigurationEntry
    ) async throws -> [String: [String]]? {
        var values: [String: [String]] = [:]
        var missing: [String] = []
        var sourcesByPath: [String: [URL]] = [:]
        var stampsByPath: [String: [GitPendingSourceStamp]] = [:]
        for path in paths {
            var sources = directories.sources + [
                directories.common.appendingPathComponent("info/attributes"),
                directories.git.appendingPathComponent("index"), configuration.attributeFile
            ] + systemSources(named: "gitattributes", executable: reader.runner.executableURL)
            var directory = reader.rootURL.appendingPathComponent(path).deletingLastPathComponent().standardizedFileURL
            let root = reader.rootURL.standardizedFileURL
            guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else { return nil }
            while true {
                sources.append(directory.appendingPathComponent(".gitattributes"))
                if directory == root { break }
                directory.deleteLastPathComponent()
            }
            sources = unique(sources)
            let stamps = try snapshot(sources)
            sourcesByPath[path] = sources
            stampsByPath[path] = stamps
            let cacheKey = root.path + "\0" + path
            if let cached = attributes[cacheKey], cached.configuration == configuration.digest, cached.stamps == stamps {
                values[path] = cached.value
            } else {
                missing.append(path)
            }
        }
        for batch in GitPendingIdentityReader.pathBatches(missing) {
            let input = Data((batch.joined(separator: "\0") + "\0").utf8)
            let data = try await reader.run(["check-attr", "--all", "-z", "--stdin"], input: input)
            let fields = data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            guard fields.count.isMultiple(of: 3) else { throw CocoaError(.fileReadCorruptFile) }
            let strings = fields.compactMap { String(data: Data($0), encoding: .utf8) }
            guard strings.count == fields.count else { throw CocoaError(.fileReadCorruptFile) }
            var loaded: [String: [String]] = [:]
            for offset in stride(from: 0, to: strings.count, by: 3) {
                loaded[strings[offset], default: []].append(strings[offset + 1] + "=" + strings[offset + 2])
            }
            for path in batch {
                guard let sources = sourcesByPath[path], let before = stampsByPath[path],
                      before == (try snapshot(sources)) else { return nil }
                let value = loaded[path] ?? []
                values[path] = value
                let cacheKey = reader.rootURL.standardizedFileURL.path + "\0" + path
                if attributes.count >= 8_192, attributes[cacheKey] == nil { attributes.removeAll(keepingCapacity: true) }
                attributes[cacheKey] = AttributesEntry(configuration: configuration.digest, stamps: before, value: value)
            }
        }
        for path in paths {
            guard let sources = sourcesByPath[path], let before = stampsByPath[path],
                  before == (try snapshot(sources)) else { return nil }
        }
        return values
    }

    private func head(
        reader: GitPendingIdentityReader, directories: Directories, isUnborn: Bool
    ) async throws -> HeadEntry? {
        let sources = try headSources(directories)
        let before = try snapshot(sources)
        if let entry = heads[reader.rootURL.path], entry.stamps == before { return entry }
        let oid: String?
        do {
            oid = String(decoding: try await reader.run(["rev-parse", "--verify", "HEAD"]), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
        } catch let error as GitCommandFailure where error.exitCode == 128 && isUnborn {
            oid = nil
        }
        guard sources == (try headSources(directories)), before == (try snapshot(sources)) else { return nil }
        let entry = HeadEntry(stamps: before, oid: oid)
        if heads.count >= 128, heads[reader.rootURL.path] == nil { heads.removeAll(keepingCapacity: true) }
        heads[reader.rootURL.path] = entry
        return entry
    }

    private func headSources(_ directories: Directories) throws -> [URL] {
        var sources = directories.sources + [
            directories.common.appendingPathComponent("packed-refs"),
            directories.common.appendingPathComponent("reftable"),
            directories.common.appendingPathComponent("reftable/tables.list")
        ]
        var current = directories.git.appendingPathComponent("HEAD")
        for _ in 0..<8 {
            sources.append(current)
            guard try GitPendingFileStat.read(current) != nil else { break }
            let text = String(decoding: try smallFile(current), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("ref: ") else { break }
            let reference = String(text.dropFirst(5))
            let local = directories.git.appendingPathComponent(reference).standardizedFileURL
            let common = directories.common.appendingPathComponent(reference).standardizedFileURL
            guard common.path.hasPrefix(directories.common.standardizedFileURL.path + "/"),
                  local.path.hasPrefix(directories.git.standardizedFileURL.path + "/") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            sources += [local, common]
            current = try GitPendingFileStat.read(local) != nil ? local : common
        }
        return unique(sources)
    }

    private func referenceSources(_ reference: String, directories: Directories) throws -> [URL] {
        var sources: [URL] = []
        var reference = reference
        for _ in 0..<8 {
            let local = directories.git.appendingPathComponent(reference).standardizedFileURL
            let common = directories.common.appendingPathComponent(reference).standardizedFileURL
            guard local.path.hasPrefix(directories.git.standardizedFileURL.path + "/"),
                  common.path.hasPrefix(directories.common.standardizedFileURL.path + "/") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            sources += [local, common]
            let current = try GitPendingFileStat.read(local) != nil ? local : common
            guard try GitPendingFileStat.read(current) != nil else { break }
            let text = String(decoding: try smallFile(current), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("ref: ") else { break }
            reference = String(text.dropFirst(5))
        }
        return unique(sources)
    }

    private func smallFile(_ url: URL) throws -> Data {
        let before = try GitPendingSourceStamp(url)
        if let entry = smallFiles[url.path], entry.stamp == before { return entry.value }
        guard let size = (before.target ?? before.node)?.size, size <= 64 * 1_024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: url)
        guard before == (try GitPendingSourceStamp(url)) else { throw CocoaError(.fileReadUnknown) }
        if smallFiles.count >= 512, smallFiles[url.path] == nil { smallFiles.removeAll(keepingCapacity: true) }
        smallFiles[url.path] = SmallFileEntry(stamp: before, value: data)
        return data
    }

    private func systemSources(named name: String, executable: URL) -> [URL] {
        [URL(fileURLWithPath: "/etc/\(name)"),
         executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("etc/\(name)"),
         URL(fileURLWithPath: "/usr/local/etc/\(name)"), URL(fileURLWithPath: "/opt/homebrew/etc/\(name)")]
    }

    private func resolve(_ path: String, relativeTo directory: URL) -> URL {
        let home = GitCommandRunner.baseEnvironment["HOME"] ?? NSHomeDirectory()
        let expanded = path.hasPrefix("~/") ? home + String(path.dropFirst()) : (path as NSString).expandingTildeInPath
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded))
            .standardizedFileURL
    }

    private func unique(_ urls: [URL]) -> [URL] {
        Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
    }

    private func snapshot(_ urls: [URL]) throws -> [GitPendingSourceStamp] {
        try unique(urls).map { try GitPendingSourceStamp($0) }
    }
}
