/// Desired processing mode is independent of a one-shot attempt to open the pen.
public struct AutomaticControl {
    public enum Action: Equatable { case wait, requestPermissions, enable }
    public private(set) var requested = true
    public var pending = true
    private var prompted = false
    public init() {}
    public mutating func pause() { requested = false; pending = false }
    public mutating func request() { requested = true; pending = true; prompted = false }
    /// Mapping or display changes may retry software mode, but must never enable native mode.
    public mutating func retryIfRequested() { if requested { pending = true } }
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
