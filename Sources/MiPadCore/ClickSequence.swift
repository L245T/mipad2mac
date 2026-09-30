import Foundation
import CoreGraphics

/// Groups completed taps by physical press time. Drag, cancellation, right click and scroll reset it.
public struct ClickSequence {
    private struct Tap {
        var point: CGPoint
        var started: TimeInterval
        var count: Int64
        var dragged = false
    }
    private var previous: Tap?
    private var active: Tap?
    public init() {}

    public mutating func begin(at point: CGPoint, now: TimeInterval, interval: TimeInterval) -> Int64 {
        var count: Int64 = 1
        if active == nil, let previous, now.isFinite, interval.isFinite, interval > 0,
           now >= previous.started, now - previous.started < interval,
           hypot(point.x - previous.point.x, point.y - previous.point.y) < 5 {
            count = previous.count == Int64.max ? previous.count : previous.count + 1
        }
        active = Tap(point: point, started: now, count: count)
        previous = nil
        return count
    }
    public mutating func drag(to point: CGPoint) {
        guard let active, hypot(point.x - active.point.x, point.y - active.point.y) >= 4 else { return }
        self.active?.dragged = true
        previous = nil
    }
    public mutating func end(now: TimeInterval, interval: TimeInterval) {
        if let active, !active.dragged, now.isFinite, active.started.isFinite,
           interval.isFinite, interval > 0, now >= active.started, now - active.started < interval {
            previous = active
        } else { previous = nil }
        active = nil
    }
    public mutating func reset() { previous = nil; active = nil }
}
