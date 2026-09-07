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
}
