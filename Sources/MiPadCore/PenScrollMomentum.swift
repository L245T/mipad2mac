import Foundation
import CoreGraphics

public final class ScrollMomentumPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var enabled: Bool {
        get { defaults.object(forKey: "penScrollMomentumEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "penScrollMomentumEnabled") }
    }
}

public enum PenMomentumPhase { case began, changed, ended }
public struct PenMomentumEvent {
    public let anchor: CGPoint
    public let phase: PenMomentumPhase
    public let horizontal: Int32
    public let vertical: Int32
}

/// Recent motion launches a bounded exponential coast; stationary pressure never launches one.
public struct PenScrollMomentum {
    private struct Entry { let time: Double; let position: Double; let pressure: Double }
    private var samples: [Entry] = []
    private var anchor = CGPoint.zero
    private var axis = PenScrollAxis.vertical
    private var velocity = 0.0
    private var remainder = 0.0
    private var lastTick = 0.0
    private var launched = 0.0
    private var began = false
    private var direction = 0.0
    // Flutter's iOS friction model: 0.135 retention per second (0.998 per millisecond).
    private static let decayRate = -log(0.135)
    public private(set) var isCoasting = false
    public init() {}
    public mutating func start(anchor: CGPoint, axis: PenScrollAxis, now: Double) {
        self = Self(); self.anchor = anchor; self.axis = axis
        samples = [Entry(time: now, position: coordinate(anchor), pressure: 0.5)]
    }
    public mutating func record(_ point: CGPoint, pressure: Double, now: Double) {
        guard !isCoasting, now.isFinite, let previous = samples.last, now > previous.time else { return }
        let position = coordinate(point)
        guard position.isFinite else { return }
        let delta = position - previous.position
        // A deliberate reversal must not fling in the earlier direction.
        if abs(delta) > 0.5 {
            if direction != 0 && delta * direction < 0 { samples = [previous] }
            direction = delta.sign == .minus ? -1 : 1
        }
        samples.append(Entry(time: now, position: position, pressure: pressure.isFinite ? min(1, max(0, pressure)) : 0.5))
        while samples.count > 2 && samples[1].time < now - 0.1 { samples.removeFirst() }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
    }
    public mutating func lift(now: Double, enabled: Bool) -> Bool {
        guard enabled, now.isFinite, let first = samples.first, let last = samples.last,
              now >= last.time, now - last.time <= 0.04, last.time - first.time >= 0.008 else {
            self = Self(); return false
        }
        let speed = releaseVelocity(first: first, last: last)
        guard speed.isFinite, abs(speed) >= 120 else { self = Self(); return false }
        // Pressure has only a modest influence; velocity remains the primary input.
        let pressure = samples.dropFirst().map(\.pressure).reduce(0, +) / Double(max(1, samples.count - 1))
        velocity = min(5000, max(-5000, speed * (0.85 + pressure * 0.3)))
        isCoasting = true; lastTick = now; launched = now; samples.removeAll(); return true
    }
    private func releaseVelocity(first: Entry, last: Entry) -> Double {
        // Use three equal recent time windows rather than three raw HID reports:
        // dense reports otherwise amplify coordinate quantization and vary with report rate.
        // The weights follow Flutter's macOS fling tracker; our windows span at most 60 ms.
        let span = min(0.06, last.time - first.time), dt = span / 3
        func position(at time: Double) -> Double {
            for i in 1..<samples.count where samples[i].time >= time {
                let a = samples[i - 1], b = samples[i]
                let fraction = min(1, max(0, (time - a.time) / (b.time - a.time)))
                return a.position + (b.position - a.position) * fraction
            }
            return last.position
        }
        let a = position(at: last.time - span), b = position(at: last.time - dt * 2)
        let c = position(at: last.time - dt), d = last.position
        return ((b - a) * 0.15 + (c - b) * 0.65 + (d - c) * 0.2) / dt
    }
    public mutating func tick(now: Double) -> PenMomentumEvent? {
        guard isCoasting, now.isFinite else { return nil }
        let dt = now - lastTick
        guard dt > 0 else { return nil }
        // A stalled run loop must never catch up with a large late jump.
        if dt > 0.1 || now - launched >= 3 || abs(velocity) < 18 { return cancel() }
        let decay = exp(-Self.decayRate * dt)
        remainder += velocity / Self.decayRate * (1 - decay)
        velocity *= decay; lastTick = now
        let pixels = remainder.rounded(.towardZero); remainder -= pixels
        guard pixels != 0 else { return nil }
        let phase: PenMomentumPhase = began ? .changed : .began
        began = true
        return event(phase, pixels: Int32(pixels))
    }
    public mutating func cancel() -> PenMomentumEvent? {
        let end = isCoasting && began ? event(.ended, pixels: 0) : nil
        self = Self(); return end
    }
    private func coordinate(_ point: CGPoint) -> Double { axis == .vertical ? point.y : point.x }
    private func event(_ phase: PenMomentumPhase, pixels: Int32) -> PenMomentumEvent {
        PenMomentumEvent(anchor: anchor, phase: phase, horizontal: axis == .horizontal ? pixels : 0,
                         vertical: axis == .vertical ? pixels : 0)
    }
}
