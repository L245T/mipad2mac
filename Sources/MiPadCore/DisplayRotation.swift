import Foundation

public enum DisplayRotationMode: Int, CaseIterable {
    case system = -1, degrees0 = 0, degrees90 = 90, degrees180 = 180, degrees270 = 270
    public var title: String { self == .system ? "跟随系统" : "\(rawValue)°" }
    public func angle(systemAngle: Double) -> Int {
        guard self == .system else { return rawValue }
        guard systemAngle.isFinite else { return 0 }
        let normalized = (systemAngle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        // Only quarter-turn mappings are supported; tolerate numeric rounding noise.
        let quarter = (normalized / 90).rounded() * 90
        guard abs(normalized - quarter) < 0.01 else { return 0 }
        return Int(quarter) % 360
    }
}

public final class DisplayRotationPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var mode: DisplayRotationMode {
        get {
            guard let value = defaults.object(forKey: "penDisplayRotationMode") as? NSNumber,
                  let mode = DisplayRotationMode.allCases.first(where: { Double($0.rawValue) == value.doubleValue }) else { return .system }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: "penDisplayRotationMode") }
    }
}
