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
        guard !excluded, let bundleID = PenApplicationID.normalize(bundleID) else { return .pointer }
        return configuredMode(for: bundleID) ?? .browse
    }
    /// Distinguishes a stored pointer choice from the default for a previously unknown application.
    public func configuredMode(for bundleID: String) -> PenNavigationMode? {
        guard let id = PenApplicationID.normalize(bundleID),
              let modes = defaults.dictionary(forKey: "penNavigationApplicationModes") as? [String: String],
              let value = PenApplicationID.dictionary(modes)[id] else { return nil }
        return PenNavigationMode(rawValue: value)
    }
    public func set(_ mode: PenNavigationMode, for bundleID: String, name: String) {
        guard let bundleID = PenApplicationID.normalize(bundleID) else { return }
        var modes = defaults.dictionary(forKey: "penNavigationApplicationModes") as? [String: String] ?? [:]
        modes = modes.filter { PenApplicationID.normalize($0.key) != bundleID }
        modes[bundleID] = mode.rawValue
        defaults.set(modes, forKey: "penNavigationApplicationModes")
        var names = applications.filter { PenApplicationID.normalize($0.key) != bundleID }; names[bundleID] = name
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
    /// Only an uncancelled pending contact lifted before any drag/scroll/right click.
    public var completedTap: Bool
    public init(pointer: [PointerEvent] = [], scroll: [PenScrollEvent] = [], completedTap: Bool = false) {
        self.pointer = pointer; self.scroll = scroll; self.completedTap = completedTap
    }
}
