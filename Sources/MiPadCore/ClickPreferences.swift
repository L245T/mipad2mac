import Foundation

/// Additional spatial tolerance for consecutive taps; does not change the OS click interval.
public final class ClickPreferences {
    public static let defaultTolerance = 4.0
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public static func validTolerance(_ value: Double) -> Double {
        value.isFinite ? min(18, max(0, value.rounded())) : defaultTolerance
    }
    public var jitterTolerance: Double {
        get {
            guard let number = defaults.object(forKey: "penMultiClickJitterTolerance") as? NSNumber else {
                return Self.defaultTolerance
            }
            return Self.validTolerance(number.doubleValue)
        }
        set { defaults.set(Self.validTolerance(newValue), forKey: "penMultiClickJitterTolerance") }
    }
}
