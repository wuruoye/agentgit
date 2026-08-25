import Foundation

public enum WorktreeListParseError: Error, Equatable, Sendable {
    case invalidUTF8
    case missingWorktreePath
}

public enum WorktreeListParser {
    public static func parse(_ data: Data) throws -> [GitWorktree] {
        var records: [[String]] = []
        var fields: [String] = []

        for bytes in data.split(separator: 0, omittingEmptySubsequences: false) {
            guard !bytes.isEmpty else {
                if !fields.isEmpty {
                    records.append(fields)
                    fields.removeAll(keepingCapacity: true)
                }
                continue
            }

            guard let field = String(data: Data(bytes), encoding: .utf8) else {
                throw WorktreeListParseError.invalidUTF8
            }
            fields.append(field)
        }

        if !fields.isEmpty {
            records.append(fields)
        }

        return try records.map(parseRecord)
    }

    private static func parseRecord(_ fields: [String]) throws -> GitWorktree {
        guard
            let worktreeField = fields.first(where: { $0.hasPrefix("worktree ") })
        else {
            throw WorktreeListParseError.missingWorktreePath
        }

        let path = String(worktreeField.dropFirst("worktree ".count))
        var headOID: String?
        var branchRef: String?
        var isBare = false
        var isDetached = false
        var lockedReason: String?
        var prunableReason: String?

        for field in fields {
            if field.hasPrefix("HEAD ") {
                headOID = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch ") {
                branchRef = String(field.dropFirst("branch ".count))
            } else if field == "bare" {
                isBare = true
            } else if field == "detached" {
                isDetached = true
            } else if field == "locked" {
                lockedReason = ""
            } else if field.hasPrefix("locked ") {
                lockedReason = String(field.dropFirst("locked ".count))
            } else if field == "prunable" {
                prunableReason = ""
            } else if field.hasPrefix("prunable ") {
                prunableReason = String(field.dropFirst("prunable ".count))
            }
        }

        return GitWorktree(
            rootURL: URL(fileURLWithPath: path, isDirectory: true),
            headOID: headOID,
            branchRef: branchRef,
            isBare: isBare,
            isDetached: isDetached,
            lockedReason: lockedReason,
            prunableReason: prunableReason
        )
    }
}
