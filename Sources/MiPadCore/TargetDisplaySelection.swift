/// Manual display choices are session-only. Never persists a transient display ID or a name.
public struct TargetDisplaySelection {
    public private(set) var isManual = false
    public private(set) var displayID: UInt32?
    public init() {}
    public mutating func choose(_ id: UInt32?) { isManual = true; displayID = id }
    public mutating func refresh(available: [UInt32]) {
        if let displayID, !available.contains(displayID) {
            self.displayID = nil; isManual = false
        }
    }
}
