import Foundation

func compactRelativeTime(
    _ date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .current
) -> String {
    let elapsed = max(0, now.timeIntervalSince(date))
    if elapsed < 60 {
        return "now"
    }
    if elapsed < 60 * 60 {
        return "\(Int(elapsed / 60))m"
    }
    if elapsed < 24 * 60 * 60 {
        return "\(Int(elapsed / (60 * 60)))h"
    }
    if elapsed < 30 * 24 * 60 * 60 {
        return "\(Int(elapsed / (24 * 60 * 60)))d"
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(.dateTime.year().month(.abbreviated).day())
}
