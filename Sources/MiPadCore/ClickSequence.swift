import Foundation
import CoreGraphics

/// Groups completed taps by physical press time. Drag, cancellation, right click and scroll reset it.
public struct ClickSequence {
    private struct Tap {
        var point: CGPoint
        var origin: CGPoint
        var dragTolerance: Double
        var started: TimeInterval
        var count: Int64
        var dragged = false
    }
    private var previous: Tap?
    private var active: Tap?
    public init() {}

    /// Looks ahead without consuming the previous tap, so navigation can honor a multi-tap drag.
    public func nextCount(at point: CGPoint, now: TimeInterval, interval: TimeInterval, extraTolerance: Double = 0) -> Int64 {
        var count: Int64 = 1
        let tolerance = ClickPreferences.validTolerance(extraTolerance)
        if active == nil, let previous, now.isFinite, interval.isFinite, interval > 0,
           now >= previous.started, now - previous.started < interval,
           hypot(point.x - (tolerance > 0 ? previous.origin.x : previous.point.x),
                 point.y - (tolerance > 0 ? previous.origin.y : previous.point.y)) < 5 + tolerance {
            count = previous.count == Int64.max ? previous.count : previous.count + 1
        }
        return count
    }
    public mutating func begin(at point: CGPoint, now: TimeInterval, interval: TimeInterval, extraTolerance: Double = 0) -> Int64 {
        let tolerance = ClickPreferences.validTolerance(extraTolerance)
        let count = nextCount(at: point, now: now, interval: interval, extraTolerance: tolerance)
        let origin = count > 1 ? previous!.origin : point
        active = Tap(point: point, origin: origin, dragTolerance: 4 + tolerance, started: now, count: count)
        previous = nil
        return count
    }
    public mutating func drag(to point: CGPoint) {
        guard let active, hypot(point.x - active.point.x, point.y - active.point.y) >= active.dragTolerance else { return }
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
