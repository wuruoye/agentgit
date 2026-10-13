import Foundation

/// 同一完整文件身份共用一次读取；最后一个调用方离开时取消尚未完成的读取。
public actor GitPendingDiffRequests {
    private struct Entry {
        let id: UUID
        let task: Task<GitFileDiff, any Error>
        var callers: Set<UUID>
    }

    private var entries: [GitPendingDiffIdentity: Entry] = [:]

    public init() {}

    public func value(
        for identity: GitPendingDiffIdentity,
        operation: @escaping @Sendable () async throws -> GitFileDiff
    ) async throws -> GitFileDiff {
        try Task.checkCancellation()
        let caller = UUID()
        let entry: Entry
        if var current = entries[identity] {
            current.callers.insert(caller)
            entries[identity] = current
            entry = current
        } else {
            entry = Entry(id: UUID(), task: Task { try await operation() }, callers: [caller])
            entries[identity] = entry
        }
        defer { release(identity, entryID: entry.id, caller: caller) }
        let diff = try await withTaskCancellationHandler {
            let diff = try await entry.task.value
            try Task.checkCancellation()
            return diff
        } onCancel: {
            Task { await self.release(identity, entryID: entry.id, caller: caller) }
        }
        return diff
    }

    private func release(_ identity: GitPendingDiffIdentity, entryID: UUID, caller: UUID) {
        guard var entry = entries[identity], entry.id == entryID else { return }
        entry.callers.remove(caller)
        if entry.callers.isEmpty {
            entries[identity] = nil
            entry.task.cancel()
        } else {
            entries[identity] = entry
        }
    }
}
