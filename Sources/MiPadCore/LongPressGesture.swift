import Foundation
import CoreGraphics

/// Integer tolerance with stable legacy names for previously saved five-level preferences.
public struct LongPressJitterFilter: RawRepresentable, Hashable, CaseIterable {
    public let tolerance: Double
    public init(tolerance: Double) {
        self.tolerance = tolerance.isFinite ? min(18, max(0, tolerance.rounded())) : 4
    }
    public init?(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "veryHigh": self = .veryHigh
        default:
            guard let value = Int(rawValue), (0...18).contains(value) else { return nil }
            self.init(tolerance: Double(value))
        }
    }
    public var rawValue: String {
        switch tolerance {
        case 0: return "none"
        case 2: return "low"
        case 4: return "medium"
        case 8: return "high"
        case 12: return "veryHigh"
        default: return String(Int(tolerance))
        }
    }
    public var title: String {
        switch tolerance {
        case 0: return "无"
        case 2: return "低"
        case 4: return "中"
        case 8: return "高"
        case 12: return "极高"
        case 18: return "最高"
        default: return String(Int(tolerance))
        }
    }
    public static let none = Self(tolerance: 0)
    public static let low = Self(tolerance: 2)
    public static let medium = Self(tolerance: 4)
    public static let high = Self(tolerance: 8)
    public static let veryHigh = Self(tolerance: 12)
    public static let maximum = Self(tolerance: 18)
    public static let landmarks: [Self] = [.none, .low, .medium, .high, .veryHigh, .maximum]
    public static var allCases: [Self] { (0...18).map { Self(tolerance: Double($0)) } }
}

/// Ordinary pointer contacts are deferred; excluded drawing applications use PointerGesture unchanged.
public struct LongPressGesture {
    private enum Phase { case idle, pending, dragging, scrolling, direct, completed, suppressed }
    private var phase = Phase.idle
    private var direct = PointerGesture()
    private var origin = CGPoint.zero
    private var last = CGPoint.zero
    private var jitterFilter = LongPressJitterFilter.medium
    private var navigationMode = PenNavigationMode.pointer
    private var scrollAxis = PenScrollAxis.vertical
    private var scrollRemainder = 0.0
    public private(set) var deadline: TimeInterval?
    public var hasScheduledClick: Bool { deadline != nil }
    public var isIdle: Bool { phase == .idle }
    public var isScrolling: Bool { phase == .scrolling }
    public var isPending: Bool { phase == .pending }
    public init() {}

    public mutating func consume(_ sample: Sample, mapping: Mapping, now: TimeInterval,
                                 enabled: Bool, delay: TimeInterval, drawing: Bool, jitterFilter: LongPressJitterFilter = .medium) -> [PointerEvent] {
        consumeNavigation(sample, mapping: mapping, now: now, enabled: enabled, delay: delay,
                          drawing: drawing, jitterFilter: jitterFilter).pointer
    }

    /// One contact owns exactly one interpretation until lift, including after cancellation.
    public mutating func consumeNavigation(_ sample: Sample, mapping: Mapping, now: TimeInterval,
                                 enabled: Bool, delay: TimeInterval, drawing: Bool,
                                 jitterFilter: LongPressJitterFilter = .medium,
                                 navigation: PenNavigationMode = .pointer) -> PenGestureEvents {
        let contact = sample.touching && sample.inRange && !sample.eraser
        if phase == .completed {
            // The context menu owns subsequent motion. Never click or drag again until a new contact.
            if !contact { phase = .idle; deadline = nil }
            if !sample.inRange || !sample.positionValid || sample.eraser ||
                movedBeyondTolerance(mapping.point(x: sample.x, y: sample.y)) { deadline = nil }
            guard sample.inRange && sample.positionValid && !sample.eraser else { return PenGestureEvents() }
            return PenGestureEvents(pointer: [PointerEvent(action: .move, point: mapping.point(x: sample.x, y: sample.y))])
        }
        if phase == .suppressed {
            if !contact { phase = .idle }
            return PenGestureEvents()
        }
        // Invalid coordinates or loss of range cancel rather than synthesize a tap.
        if !sample.inRange || sample.eraser || (contact && !sample.positionValid) {
            return cancelNavigation()
        }
        if phase == .direct {
            let event = direct.consume(sample, mapping: mapping, drawing: drawing)
            if !contact { phase = .idle }
            return PenGestureEvents(pointer: event.map { [$0] } ?? [])
        }
        if phase == .idle {
            if !contact {
                return PenGestureEvents(pointer: sample.positionValid ? [PointerEvent(action: .move, point: mapping.point(x: sample.x, y: sample.y))] : [])
            }
            navigationMode = navigation
            if !enabled && navigation == .pointer {
                phase = .direct
                return PenGestureEvents(pointer: direct.consume(sample, mapping: mapping, drawing: drawing).map { [$0] } ?? [])
            }
            self.jitterFilter = jitterFilter
            origin = mapping.point(x: sample.x, y: sample.y); last = origin
            phase = .pending
            deadline = enabled ? now + LongPressPreferences.validDelay(delay) : nil
            return PenGestureEvents(pointer: navigation == .browse ? [PointerEvent(action: .move, point: origin)] : [])
        }
        if !contact {
            if phase == .scrolling {
                phase = .idle; deadline = nil
                return PenGestureEvents(pointer: [PointerEvent(action: .move, point: last)], scroll: [PenScrollEvent(anchor: origin, phase: .ended)])
            }
            let wasPending = phase == .pending
            phase = .idle; deadline = nil
            return PenGestureEvents(pointer: wasPending ? [PointerEvent(action: .down, point: origin), PointerEvent(action: .up, point: origin)]
                : [PointerEvent(action: .up, point: last)])
        }
        let point = mapping.point(x: sample.x, y: sample.y)
        if phase == .scrolling {
            return scroll(to: point, phase: .changed)
        }
        if phase == .pending && navigationMode == .browse {
            let dx = point.x - origin.x, dy = point.y - origin.y
            guard hypot(dx, dy) >= PenScrollEvent.activationDistance else { return PenGestureEvents(pointer: [PointerEvent(action: .move, point: point)]) }
            scrollAxis = abs(dx) > abs(dy) * 1.5 ? .horizontal : .vertical
            phase = .scrolling; deadline = nil; scrollRemainder = 0
            return scroll(to: point, phase: .began)
        }
        if phase == .pending {
            // Distance from initial contact, never accumulated path length. Movement wins over time.
            guard movedBeyondTolerance(point) else { return PenGestureEvents() }
            phase = .dragging; deadline = nil; last = point
            return PenGestureEvents(pointer: [PointerEvent(action: .down, point: origin), PointerEvent(action: .drag, point: point)])
        }
        last = point
        return PenGestureEvents(pointer: [PointerEvent(action: .drag, point: point)])
    }

    private mutating func scroll(to point: CGPoint, phase: PenScrollPhase) -> PenGestureEvents {
        scrollRemainder += scrollAxis == .vertical ? point.y - last.y : point.x - last.x
        last = point
        let pixels = scrollRemainder.rounded(.towardZero)
        scrollRemainder -= pixels
        let pointer = [PointerEvent(action: .move, point: point)]
        guard pixels != 0 || phase == .began else { return PenGestureEvents(pointer: pointer) }
        return PenGestureEvents(pointer: pointer, scroll: [PenScrollEvent(anchor: origin, phase: phase,
                horizontal: scrollAxis == .horizontal ? Int32(pixels) : 0,
                vertical: scrollAxis == .vertical ? Int32(pixels) : 0)])
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
    public mutating func cancel() -> [PointerEvent] { cancelNavigation().pointer }

    public mutating func cancelNavigation() -> PenGestureEvents {
        let scroll = phase == .scrolling ? [PenScrollEvent(anchor: origin, phase: .cancelled)] : []
        var events: [PointerEvent] = []
        if phase == .direct, let event = direct.release() { events = [event] }
        if phase == .dragging { events = [PointerEvent(action: .up, point: last)] }
        if phase != .idle { phase = .suppressed }
        deadline = nil
        scrollRemainder = 0
        return PenGestureEvents(pointer: events, scroll: scroll)
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
