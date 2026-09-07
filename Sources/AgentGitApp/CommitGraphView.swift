import AgentGitCore
import AppKit
import SwiftUI

struct CommitGraphLayout: Equatable, Sendable {
    let rowsByCommitID: [GitCommit.ID: CommitGraphRow]
    let laneCount: Int
    private let continuation: CommitGraphContinuation

    init(commits: [GitCommit]) {
        self = Self.extending(
            rows: [:],
            maximumLaneCount: 1,
            continuation: CommitGraphContinuation(
                lanes: [],
                allocator: CommitLaneColorAllocator(),
                hasProcessedCommits: false
            ),
            with: commits
        )
    }

    func appending(_ commits: [GitCommit]) -> CommitGraphLayout {
        guard !commits.isEmpty else {
            return self
        }
        return Self.extending(
            rows: rowsByCommitID,
            maximumLaneCount: laneCount,
            continuation: continuation,
            with: commits
        )
    }

    private init(
        rowsByCommitID: [GitCommit.ID: CommitGraphRow],
        laneCount: Int,
        continuation: CommitGraphContinuation
    ) {
        self.rowsByCommitID = rowsByCommitID
        self.laneCount = laneCount
        self.continuation = continuation
    }

    private static func extending(
        rows existingRows: [GitCommit.ID: CommitGraphRow],
        maximumLaneCount initialMaximumLaneCount: Int,
        continuation: CommitGraphContinuation,
        with commits: [GitCommit]
    ) -> CommitGraphLayout {
        var lanes = continuation.lanes
        var allocator = continuation.allocator
        var rows = existingRows
        var maximumLaneCount = initialMaximumLaneCount
        var hasProcessedCommits = continuation.hasProcessedCommits

        for commit in commits {
            guard !Task.isCancelled else {
                break
            }
            let wasExpected = lanes.contains { $0.targetOID == commit.oid }
            if !wasExpected {
                let colorIndex = allocator.take(avoiding: Set(lanes.map(\.colorIndex)))
                lanes.insert(
                    ActiveCommitLane(targetOID: commit.oid, colorIndex: colorIndex),
                    at: 0
                )
            }

            guard let nodeLane = lanes.firstIndex(where: { $0.targetOID == commit.oid }) else {
                continue
            }
            let topLanes = lanes
            let nodeColorIndex = lanes[nodeLane].colorIndex
            let parents = commit.parentOIDs.reduce(into: [String]()) { result, oid in
                if !result.contains(oid) {
                    result.append(oid)
                }
            }

            var bottomLanes = lanes
            bottomLanes.remove(at: nodeLane)
            var insertionIndex = min(nodeLane, bottomLanes.count)
            for (parentIndex, parentOID) in parents.enumerated() {
                if bottomLanes.contains(where: { $0.targetOID == parentOID }) {
                    continue
                }
                let colorIndex = parentIndex == 0
                    ? nodeColorIndex
                    : allocator.take(avoiding: Set(bottomLanes.map(\.colorIndex)))
                bottomLanes.insert(
                    ActiveCommitLane(targetOID: parentOID, colorIndex: colorIndex),
                    at: insertionIndex
                )
                insertionIndex += 1
            }

            var segments: [CommitGraphSegment] = []
            for (topIndex, lane) in topLanes.enumerated() where topIndex != nodeLane {
                guard let bottomIndex = bottomLanes.firstIndex(where: {
                    $0.targetOID == lane.targetOID
                }) else {
                    continue
                }
                segments.append(
                    CommitGraphSegment(
                        startLane: topIndex,
                        endLane: bottomIndex,
                        startPosition: .top,
                        endPosition: .bottom,
                        colorIndex: lane.colorIndex
                    )
                )
            }
            if wasExpected || hasProcessedCommits {
                segments.append(
                    CommitGraphSegment(
                        startLane: nodeLane,
                        endLane: nodeLane,
                        startPosition: .top,
                        endPosition: .node,
                        colorIndex: nodeColorIndex
                    )
                )
            }
            for parentOID in parents {
                guard let parentLane = bottomLanes.firstIndex(where: {
                    $0.targetOID == parentOID
                }) else {
                    continue
                }
                segments.append(
                    CommitGraphSegment(
                        startLane: nodeLane,
                        endLane: parentLane,
                        startPosition: .node,
                        endPosition: .bottom,
                        colorIndex: bottomLanes[parentLane].colorIndex
                    )
                )
            }

            let rowLaneCount = max(max(topLanes.count, bottomLanes.count), nodeLane + 1)
            maximumLaneCount = max(maximumLaneCount, rowLaneCount)
            rows[commit.id] = CommitGraphRow(
                nodeLane: nodeLane,
                nodeColorIndex: nodeColorIndex,
                isMerge: parents.count > 1,
                hasReferences: !commit.refNames.isEmpty,
                laneCount: rowLaneCount,
                segments: segments
            )
            lanes = bottomLanes
            hasProcessedCommits = true
        }

        return CommitGraphLayout(
            rowsByCommitID: rows,
            laneCount: maximumLaneCount,
            continuation: CommitGraphContinuation(
                lanes: lanes,
                allocator: allocator,
                hasProcessedCommits: hasProcessedCommits
            )
        )
    }

    var displayWidth: CGFloat {
        max(14, CGFloat(renderedLaneCount) * 9 + 5)
    }

    var renderedLaneCount: Int {
        min(laneCount, Self.maximumRenderedLaneCount)
    }

    private static let maximumRenderedLaneCount = 5
}

struct CommitGraphRow: Equatable, Sendable {
    let nodeLane: Int
    let nodeColorIndex: Int
    let isMerge: Bool
    let hasReferences: Bool
    let laneCount: Int
    let segments: [CommitGraphSegment]
}

struct CommitGraphSegment: Equatable, Sendable {
    let startLane: Int
    let endLane: Int
    let startPosition: CommitGraphVerticalPosition
    let endPosition: CommitGraphVerticalPosition
    let colorIndex: Int
}

enum CommitGraphVerticalPosition: CGFloat, Equatable, Sendable {
    case top = 0
    case node = 0.5
    case bottom = 1
}

enum CommitGraphMetrics {
    /// Commit 行高。图谱 Canvas、Pending 标记和 Commit 行共用它，改一处三处一起变。
    static let rowHeight: CGFloat = 50
    static let horizontalPadding: CGFloat = 7
    static let maximumNodeExtent: CGFloat = 6.5
}

func commitGraphLaneX(
    lane: Int,
    laneCount: Int,
    width: CGFloat
) -> CGFloat {
    let count = max(1, min(laneCount, 5))
    let displayedLane = min(max(0, lane), count - 1)
    let horizontalPadding = min(
        CommitGraphMetrics.horizontalPadding,
        max(0, width / 2)
    )
    let availableWidth = max(0, width - horizontalPadding * 2)
    let laneSpacing = count == 1
        ? 0
        : min(9, availableWidth / CGFloat(count - 1))
    return count == 1
        ? width / 2
        : horizontalPadding + CGFloat(displayedLane) * laneSpacing
}

struct CommitGraphView: View {
    let row: CommitGraphRow
    let totalLaneCount: Int
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            for segment in row.segments {
                let start = point(
                    lane: segment.startLane,
                    position: segment.startPosition,
                    size: size
                )
                let end = point(
                    lane: segment.endLane,
                    position: segment.endPosition,
                    size: size
                )
                var path = Path()
                path.move(to: start)
                if segment.startLane == segment.endLane {
                    path.addLine(to: end)
                } else {
                    let middleY = (start.y + end.y) / 2
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: middleY),
                        control2: CGPoint(x: end.x, y: middleY)
                    )
                }
                context.stroke(
                    path,
                    with: .color(Self.color(segment.colorIndex)),
                    lineWidth: 1.4
                )
            }

            let node = point(lane: row.nodeLane, position: .node, size: size)
            let radius: CGFloat = row.isMerge || row.hasReferences ? 4 : 3.5
            let nodeRect = CGRect(
                x: node.x - radius,
                y: node.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let nodePath = Path(
                roundedRect: nodeRect,
                cornerRadius: row.isMerge ? 1.5 : 2
            )
            if row.isMerge {
                context.fill(
                    nodePath,
                    with: .color(Color(nsColor: AgentGitPalette.canvas))
                )
                context.stroke(
                    nodePath,
                    with: .color(Self.color(row.nodeColorIndex)),
                    lineWidth: 1.4
                )
            } else {
                context.fill(
                    nodePath,
                    with: .color(Self.color(row.nodeColorIndex))
                )
                if row.hasReferences {
                    let referencePath = Path(
                        roundedRect: nodeRect.insetBy(dx: -2, dy: -2),
                        cornerRadius: 2.5
                    )
                    context.stroke(
                        referencePath,
                        with: .color(Self.color(row.nodeColorIndex).opacity(0.45)),
                        lineWidth: 1
                    )
                }
            }
        }
        .frame(width: width, height: CommitGraphMetrics.rowHeight)
        .accessibilityHidden(true)
    }

    private func point(
        lane: Int,
        position: CommitGraphVerticalPosition,
        size: CGSize
    ) -> CGPoint {
        return CGPoint(
            x: commitGraphLaneX(
                lane: lane,
                laneCount: totalLaneCount,
                width: size.width
            ),
            y: size.height * position.rawValue
        )
    }

    private static func color(_ index: Int) -> Color {
        palette[index % palette.count]
    }

    private static let palette: [Color] = [
        Color(nsColor: AgentGitPalette.commitEdge0),
        Color(nsColor: AgentGitPalette.commitEdge1),
        Color(nsColor: AgentGitPalette.commitEdge2),
        Color(nsColor: AgentGitPalette.commitEdge3),
        Color(nsColor: AgentGitPalette.commitEdge4),
        Color(nsColor: AgentGitPalette.commitEdge5)
    ]
}

private struct CommitGraphContinuation: Equatable, Sendable {
    let lanes: [ActiveCommitLane]
    let allocator: CommitLaneColorAllocator
    let hasProcessedCommits: Bool
}

private struct ActiveCommitLane: Equatable, Sendable {
    let targetOID: String
    let colorIndex: Int
}

private struct CommitLaneColorAllocator: Equatable, Sendable {
    private var nextColorIndex = 0

    mutating func take(avoiding usedColorIndexes: Set<Int>) -> Int {
        let colorCount = 6
        for offset in 0..<colorCount {
            let candidate = (nextColorIndex + offset) % colorCount
            if !usedColorIndexes.contains(candidate) {
                nextColorIndex = (candidate + 1) % colorCount
                return candidate
            }
        }
        let candidate = nextColorIndex % colorCount
        nextColorIndex = (nextColorIndex + 1) % colorCount
        return candidate
    }
}
