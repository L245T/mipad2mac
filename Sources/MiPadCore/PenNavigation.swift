import Foundation
import CoreGraphics

public enum PenNavigationMode: String, CaseIterable {
    case pointer, browse
    public var title: String { self == .pointer ? "指针" : "浏览" }
}

public final class PenNavigationPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var applications: [String: String] {
        defaults.dictionary(forKey: "penNavigationApplicationNames") as? [String: String] ?? [:]
    }
    public var hasBrowseApplications: Bool {
        (defaults.dictionary(forKey: "penNavigationApplicationModes") as? [String: String] ?? [:]).values.contains(PenNavigationMode.browse.rawValue)
    }
    public func mode(for bundleID: String?, excluded: Bool = false) -> PenNavigationMode {
        guard !excluded, let bundleID, !bundleID.isEmpty,
              let modes = defaults.dictionary(forKey: "penNavigationApplicationModes") as? [String: String],
              let value = modes[bundleID.lowercased()], let mode = PenNavigationMode(rawValue: value) else { return .pointer }
        return mode
    }
    public func set(_ mode: PenNavigationMode, for bundleID: String, name: String) {
        guard !bundleID.isEmpty else { return }
        var modes = defaults.dictionary(forKey: "penNavigationApplicationModes") as? [String: String] ?? [:]
        modes[bundleID.lowercased()] = mode.rawValue
        defaults.set(modes, forKey: "penNavigationApplicationModes")
        var names = applications; names[bundleID] = name
        defaults.set(names, forKey: "penNavigationApplicationNames")
    }
}

public enum PenScrollAxis { case vertical, horizontal }
public enum PenScrollPhase { case began, changed, ended, cancelled }
public struct PenScrollEvent: Equatable {
    /// Separate from long-press jitter tolerance, in mapped desktop logical points.
    public static let activationDistance = 6.0
    public let anchor: CGPoint
    public let phase: PenScrollPhase
    public let horizontal: Int32
    public let vertical: Int32
    public init(anchor: CGPoint, phase: PenScrollPhase, horizontal: Int32 = 0, vertical: Int32 = 0) {
        self.anchor = anchor; self.phase = phase; self.horizontal = horizontal; self.vertical = vertical
    }
}
public struct PenGestureEvents {
    public var pointer: [PointerEvent]
    public var scroll: [PenScrollEvent]
    public init(pointer: [PointerEvent] = [], scroll: [PenScrollEvent] = []) {
        self.pointer = pointer; self.scroll = scroll
    }
}

/// A deliberately temporary action, never a saved application mode.
public struct TemporaryScrollRequest {
    private var deadline: TimeInterval?
    public init() {}
    public func isArmed(now: TimeInterval) -> Bool { deadline.map { now < $0 } ?? false }
    public mutating func arm(now: TimeInterval) { deadline = now + 30 }
    public mutating func cancel() { deadline = nil }
    /// Own UI contacts do not consume the screen button's request. The first external contact does.
    public mutating func consume(now: TimeInterval, optionHeld: Bool, mode: PenApplicationMode,
                                 externalWindow: Bool, blockedWindow: Bool = false) -> Bool {
        guard externalWindow else { return false }
        // Preserve native Option-drag actions in ordinary pointer profiles (e.g. file duplication).
        let requested = (optionHeld && mode == .browse) || isArmed(now: now)
        deadline = nil
        return requested && mode != .drawing && !blockedWindow
    }
}
