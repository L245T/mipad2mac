import Foundation
import CoreGraphics

public enum LongPressJitterFilter: String, CaseIterable {
    case veryHigh, high, medium, low, none
    public var title: String {
        switch self {
        case .veryHigh: return "极高"
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        case .none: return "无"
        }
    }
    /// Logical screen points; medium preserves the original movement tolerance.
    public var tolerance: Double {
        switch self {
        case .veryHigh: return 12
        case .high: return 8
        case .medium: return 4
        case .low: return 2
        case .none: return 0
        }
    }
}

/// Ordinary pointer contacts are deferred; excluded drawing applications use PointerGesture unchanged.
public struct LongPressGesture {
    private enum Phase { case idle, pending, dragging, direct, completed, suppressed }
    private var phase = Phase.idle
    private var direct = PointerGesture()
    private var origin = CGPoint.zero
    private var last = CGPoint.zero
    private var jitterFilter = LongPressJitterFilter.medium
    public private(set) var deadline: TimeInterval?
    public var hasScheduledClick: Bool { deadline != nil }
    public var isIdle: Bool { phase == .idle }
    public var isPending: Bool { phase == .pending }
    public init() {}

    public mutating func consume(_ sample: Sample, mapping: Mapping, now: TimeInterval,
                                 enabled: Bool, delay: TimeInterval, drawing: Bool, jitterFilter: LongPressJitterFilter = .medium) -> [PointerEvent] {
        let contact = sample.touching && sample.inRange && !sample.eraser
        if phase == .completed {
            // The context menu owns subsequent motion. Never click or drag again until a new contact.
            if !contact { phase = .idle; deadline = nil }
            if !sample.inRange || !sample.positionValid || sample.eraser ||
                movedBeyondTolerance(mapping.point(x: sample.x, y: sample.y)) { deadline = nil }
            guard sample.inRange && sample.positionValid && !sample.eraser else { return [] }
            return [PointerEvent(action: .move, point: mapping.point(x: sample.x, y: sample.y))]
        }
        if phase == .suppressed {
            if !contact { phase = .idle }
            return []
        }
        if phase == .direct {
            let event = direct.consume(sample, mapping: mapping, drawing: drawing)
            if !contact { phase = .idle }
            return event.map { [$0] } ?? []
        }
        // Invalid coordinates or loss of range cancel rather than synthesize a tap.
        if !sample.inRange || sample.eraser || (contact && !sample.positionValid) {
            return cancel()
        }
        if phase == .idle {
            if !contact {
                return sample.positionValid ? [PointerEvent(action: .move, point: mapping.point(x: sample.x, y: sample.y))] : []
            }
            if !enabled {
                phase = .direct
                return direct.consume(sample, mapping: mapping, drawing: drawing).map { [$0] } ?? []
            }
            self.jitterFilter = jitterFilter
            origin = mapping.point(x: sample.x, y: sample.y); last = origin
            phase = .pending
            deadline = now + LongPressPreferences.validDelay(delay)
            return []
        }
        if !contact {
            let wasPending = phase == .pending
            phase = .idle; deadline = nil
            return wasPending ? [PointerEvent(action: .down, point: origin), PointerEvent(action: .up, point: origin)]
                : [PointerEvent(action: .up, point: last)]
        }
        let point = mapping.point(x: sample.x, y: sample.y)
        if phase == .pending {
            // Distance from initial contact, never accumulated path length. Movement wins over time.
            guard movedBeyondTolerance(point) else { return [] }
            phase = .dragging; deadline = nil; last = point
            return [PointerEvent(action: .down, point: origin), PointerEvent(action: .drag, point: point)]
        }
        last = point
        return [PointerEvent(action: .drag, point: point)]
    }

    private func movedBeyondTolerance(_ point: CGPoint) -> Bool {
        let distance = hypot(point.x - origin.x, point.y - origin.y)
        return jitterFilter == .none ? distance > 0 : distance >= jitterFilter.tolerance
    }

    /// Called by a separate timer, independent of diagnostics refresh and report frequency.
    public mutating func fire(now: TimeInterval, compatibility: Bool = false) -> [PointerEvent] {
        guard let deadline, now >= deadline else { return [] }
        if phase == .pending {
            phase = .completed
            self.deadline = compatibility ? now + 0.1 : nil
        } else if phase == .completed {
            self.deadline = nil
        } else { return [] }
        return [PointerEvent(action: .rightDown, point: origin), PointerEvent(action: .rightUp, point: origin)]
    }

    /// Suppress the rest of this contact so changing settings cannot start a new stroke mid-contact.
    public mutating func cancel() -> [PointerEvent] {
        var events: [PointerEvent] = []
        if phase == .direct, let event = direct.release() { events = [event] }
        if phase == .dragging { events = [PointerEvent(action: .up, point: last)] }
        if phase != .idle { phase = .suppressed }
        deadline = nil
        return events
    }

    /// A disconnect ends the physical connection; a new connection may begin with a contact report.
    public mutating func reset() { self = Self() }
}

public final class LongPressPreferences {
    public static let defaultDelay = 0.6
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public static func validDelay(_ value: Double) -> Double {
        value.isFinite ? min(2, max(0.3, value)) : defaultDelay
    }
    public var enabled: Bool {
        get { defaults.object(forKey: "penLongPressEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "penLongPressEnabled") }
    }
    public var delay: Double {
        get {
            guard let number = defaults.object(forKey: "penLongPressDelay") as? NSNumber else { return Self.defaultDelay }
            return Self.validDelay(number.doubleValue)
        }
        set { defaults.set(Self.validDelay(newValue), forKey: "penLongPressDelay") }
    }
    public var jitterFilter: LongPressJitterFilter {
        get { defaults.string(forKey: "penLongPressJitterFilter").flatMap(LongPressJitterFilter.init(rawValue:)) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "penLongPressJitterFilter") }
    }
    public var exclusions: [String: String] {
        get { defaults.dictionary(forKey: "penLongPressExcludedApps") as? [String: String] ?? ["com.adobe.Photoshop": "Adobe Photoshop"] }
        set { defaults.set(newValue, forKey: "penLongPressExcludedApps") }
    }
    public var compatibilityEnabled: Bool {
        get { defaults.object(forKey: "penRightClickCompatibilityEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "penRightClickCompatibilityEnabled") }
    }
    public var compatibilityApplications: [String: String] {
        get { defaults.dictionary(forKey: "penRightClickCompatibilityApps") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "penRightClickCompatibilityApps") }
    }
    public func usesCompatibility(for bundleID: String) -> Bool {
        enabled && compatibilityEnabled && !excludes(bundleID) &&
            compatibilityApplications.keys.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
    public func excludes(_ bundleID: String) -> Bool {
        exclusions.keys.contains { key in
            bundleID.caseInsensitiveCompare(key) == .orderedSame ||
            (key.lowercased() == "com.adobe.photoshop" && bundleID.lowercased().hasPrefix("com.adobe.photoshop."))
        }
    }
}
