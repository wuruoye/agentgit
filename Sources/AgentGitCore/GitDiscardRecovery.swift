import Foundation

public enum GitDiscardRecoveryDestination: Hashable, Sendable {
    case systemTrash
    case directory(URL)
}

public enum GitDiscardRecoveryKind: String, Codable, Sendable {
    case file
    case selection
}

public struct GitDiscardRecoveryMetadata: Codable, Equatable, Sendable {
    public let worktreePath: String
    public let relativePath: String
    public let kind: GitDiscardRecoveryKind
    public let discardedAt: Date
}

public struct GitDiscardRecoveryStore: Sendable {
    public static let systemTrash = GitDiscardRecoveryStore(
        destination: .systemTrash
    )

    public let destination: GitDiscardRecoveryDestination

    public init(destination: GitDiscardRecoveryDestination) {
        self.destination = destination
    }

    @discardableResult
    public func preserve(
        itemAt sourceURL: URL,
        worktreeURL: URL,
        relativePath: String,
        kind: GitDiscardRecoveryKind,
        movesOriginal: Bool
    ) throws -> URL {
        let fileManager = FileManager.default
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let standardizedWorktreeURL = worktreeURL.standardizedFileURL
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "AgentGit-Discard-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundleURL = temporaryRoot.appendingPathComponent(
            recoveryBundleName(for: standardizedSourceURL),
            isDirectory: true
        )
        let filesURL = bundleURL.appendingPathComponent("Files", isDirectory: true)
        let recoveredItemURL = filesURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard recoveredItemURL.path.hasPrefix(filesURL.path + "/") else {
            throw GitMutationError.pathOutsideWorktree
        }
        if case let .directory(destinationURL) = destination {
            try fileManager.createDirectory(
                at: destinationURL.standardizedFileURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.createDirectory(
            at: recoveredItemURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var originalWasMoved = false
        do {
            if movesOriginal {
                try fileManager.moveItem(
                    at: standardizedSourceURL,
                    to: recoveredItemURL
                )
                originalWasMoved = true
            } else {
                try fileManager.copyItem(
                    at: standardizedSourceURL,
                    to: recoveredItemURL
                )
            }
            let metadata = GitDiscardRecoveryMetadata(
                worktreePath: standardizedWorktreeURL.path,
                relativePath: relativePath,
                kind: kind,
                discardedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metadata).write(
                to: bundleURL.appendingPathComponent("Recovery.json"),
                options: .atomic
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: bundleURL.appendingPathComponent("Recovery.json").path
            )

            let resultingURL: URL
            switch destination {
            case .systemTrash:
                var trashedURL: NSURL?
                try fileManager.trashItem(
                    at: bundleURL,
                    resultingItemURL: &trashedURL
                )
                resultingURL = (trashedURL as URL?) ?? bundleURL
            case let .directory(destinationURL):
                let targetURL = uniqueDestinationURL(
                    bundleName: bundleURL.lastPathComponent,
                    in: destinationURL.standardizedFileURL,
                    fileManager: fileManager
                )
                try fileManager.moveItem(at: bundleURL, to: targetURL)
                resultingURL = targetURL
            }
            try? fileManager.removeItem(at: temporaryRoot)
            return resultingURL
        } catch {
            if originalWasMoved,
               fileManager.fileExists(atPath: recoveredItemURL.path),
               !fileManager.fileExists(atPath: standardizedSourceURL.path) {
                try? fileManager.createDirectory(
                    at: standardizedSourceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fileManager.moveItem(
                    at: recoveredItemURL,
                    to: standardizedSourceURL
                )
            }
            try? fileManager.removeItem(at: temporaryRoot)
            throw error
        }
    }

    private func recoveryBundleName(for sourceURL: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let itemName = sourceURL.lastPathComponent.isEmpty
            ? "Changes"
            : sourceURL.lastPathComponent
        return "AgentGit Discard \(formatter.string(from: Date())) - \(itemName)"
    }

    private func uniqueDestinationURL(
        bundleName: String,
        in directoryURL: URL,
        fileManager: FileManager
    ) -> URL {
        let initialURL = directoryURL.appendingPathComponent(
            bundleName,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: initialURL.path) else {
            return initialURL
        }
        return directoryURL.appendingPathComponent(
            "\(bundleName) \(UUID().uuidString)",
            isDirectory: true
        )
    }
}
