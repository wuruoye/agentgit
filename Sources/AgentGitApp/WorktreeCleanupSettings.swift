import Foundation

struct WorktreeCleanupSettings: Codable, Equatable {
    var isEnabled = false
    var intervalHours = 1
    var inactiveDays = 7

    var interval: TimeInterval { Double(max(1, intervalHours)) * 3_600 }
    var inactivity: TimeInterval { Double(max(1, inactiveDays)) * 86_400 }
}

struct WorktreeCleanupReport: Codable {
    let checkedAt: Date
    var removedPaths: [String] = []
    var skippedCount = 0
    var errors: [String] = []
    var runID: String?
    var durationSeconds: Double?
    var skippedWorktrees: [WorktreeCleanupSkip]?

    mutating func recordSkipped(path: String, reason: String) {
        skippedCount += 1
        if skippedWorktrees == nil { skippedWorktrees = [] }
        skippedWorktrees?.append(WorktreeCleanupSkip(path: path, reason: reason))
    }

    var diagnosticText: String {
        var lines = [
            "Checked at: \(checkedAt.ISO8601Format())",
            "Run ID: \(runID ?? "unavailable")",
            "\(removedPaths.count) removed, \(skippedCount) kept, \(errors.count) errors"
        ]
        if let durationSeconds {
            lines.append(String(format: "Duration: %.3f seconds", durationSeconds))
        }
        lines += removedPaths.map { "Removed: \($0)" }
        lines += (skippedWorktrees ?? []).map { "Kept: \($0.path)\nReason: \($0.reason)" }
        lines += errors.map { "Error: \($0)" }
        return lines.joined(separator: "\n")
    }
}

struct WorktreeCleanupSkip: Codable {
    let path: String
    let reason: String
}
