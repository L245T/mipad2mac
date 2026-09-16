/// One-shot startup intent. A user's pause and an attempted exclusive open consume it.
public struct AutomaticControl {
    public enum Action: Equatable { case wait, requestPermissions, enable }
    public var pending = true
    private var prompted = false
    public init() {}
    public mutating func pause() { pending = false }
    public mutating func request() { pending = true; prompted = false }
    public mutating func next(permissions: Bool, target: Bool, pen: Bool) -> Action {
        guard pending else { return .wait }
        guard permissions else {
            guard !prompted else { return .wait }
            prompted = true
            return .requestPermissions
        }
        guard target && pen else { return .wait }
        pending = false
        return .enable
    }
}
