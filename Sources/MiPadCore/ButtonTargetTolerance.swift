import Foundation
import CoreGraphics

/// A separate distance setting, not a jitter filter or a change to the OS click interval.
public final class ButtonTargetTolerancePreferences {
    public static let defaultRadius = 6.0
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public static func validRadius(_ value: Double) -> Double {
        value.isFinite ? min(18, max(0, value.rounded())) : defaultRadius
    }
    public var radius: Double {
        get {
            guard let value = defaults.object(forKey: "penButtonTargetRadius") as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return Self.defaultRadius }
            return Self.validRadius(value.doubleValue)
        }
        set { defaults.set(Self.validRadius(newValue), forKey: "penButtonTargetRadius") }
    }
}

public enum ButtonTargetGeometry {
    public static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
    }
    public static func distance(from point: CGPoint, to rect: CGRect) -> Double {
        guard point.x.isFinite, point.y.isFinite, valid(rect) else { return .infinity }
        return hypot(max(rect.minX - point.x, 0, point.x - rect.maxX),
                     max(rect.minY - point.y, 0, point.y - rect.maxY))
    }
    /// Complete enumeration is mandatory. Equal targets are not resolved by traversal order.
    public static func nearest(to point: CGPoint, radius: Double, frames: [CGRect], complete: Bool) -> Int? {
        guard complete, radius.isFinite, radius > 0, point.x.isFinite, point.y.isFinite else { return nil }
        guard frames.allSatisfy({ valid($0) && distance(from: point, to: $0) > 0 }) else { return nil }
        let candidates = frames.enumerated().compactMap { index, frame -> (Int, Double)? in
            guard valid(frame), min(frame.width, frame.height) < 28 else { return nil }
            let d = distance(from: point, to: frame)
            // Already inside a button is an exact hit, not an assisted miss.
            return d > 0 && d <= radius ? (index, d) : nil
        }.sorted { $0.1 < $1.1 }
        guard let first = candidates.first else { return nil }
        if candidates.count > 1, candidates[1].1 - first.1 <= 0.5 { return nil }
        return first.0
    }
    public static func clickPoint(from point: CGPoint, inside frame: CGRect) -> CGPoint {
        let insetX = min(1, frame.width / 2), insetY = min(1, frame.height / 2)
        return CGPoint(x: min(frame.maxX - insetX, max(frame.minX + insetX, point.x)),
                       y: min(frame.maxY - insetY, max(frame.minY + insetY, point.y)))
    }
    /// Never steal a click from a text/control hit. Unknown container geometry is not classified as text.
    public static func permitsMiss(roles: [String]) -> Bool {
        let containers = ["AXGroup", "AXLayoutArea", "AXUnknown", "AXWindow", "AXToolbar", "AXScrollArea", "AXWebArea"]
        let protected = ["AXButton", "AXTextField", "AXTextArea", "AXStaticText", "AXLink", "AXTitleBar",
                         "AXScrollBar", "AXSlider", "AXCheckBox", "AXRadioButton", "AXComboBox",
                         "AXPopUpButton", "AXMenu", "AXMenuItem", "AXMenuBar", "AXTabGroup"]
        return roles.first.map { containers.contains($0) } == true && !roles.contains { protected.contains($0) }
    }
}
