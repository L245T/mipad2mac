/// Tracks a newly usable pen/display pair, not display geometry notifications.
public struct TabletConnection {
    private var target: UInt32?
    public init() {}
    public mutating func observe(penReady: Bool, displayIDs: [UInt32]) -> UInt32? {
        let next = penReady && displayIDs.count == 1 ? displayIDs.first : nil
        defer { target = next }
        return next != target ? next : nil
    }
    public mutating func disconnected() { target = nil }
}
