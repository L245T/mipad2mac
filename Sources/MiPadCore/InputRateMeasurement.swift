import Foundation

/// Measures application callback arrivals, not the tablet's hardware scan clock.
public struct InputRateMeasurement {
    public let start: Double
    public let duration: Double
    public private(set) var reports = 0
    public private(set) var validPositions = 0
    public private(set) var positionChanges = 0
    public private(set) var posted = 0
    public private(set) var resetReports = 0
    public private(set) var maxGap = 0.0
    private var previousTime: Double?
    private var previousPosition: (Double, Double)?
    public init(start: Double, duration: Double = 15) {
        self.start = start; self.duration = duration
    }
    public func contains(_ time: Double) -> Bool { time >= start && time < start + duration }
    public mutating func receive(at time: Double, sample: Sample?) {
        guard contains(time) else { return }
        reports += 1
        if let previousTime { maxGap = max(maxGap, time - previousTime) }
        previousTime = time
        guard let sample else { return }
        guard sample.positionValid else { resetReports += 1; return }
        guard sample.inRange else { return }
        validPositions += 1
        if let previousPosition, previousPosition.0 != sample.x || previousPosition.1 != sample.y {
            positionChanges += 1
        }
        previousPosition = (sample.x, sample.y)
    }
    public mutating func recordPost(at time: Double) {
        if contains(time) { posted += 1 }
    }
    public var reportRate: Double { Double(reports) / duration }
    public var positionRate: Double { Double(validPositions) / duration }
    public var postRate: Double { Double(posted) / duration }
}
