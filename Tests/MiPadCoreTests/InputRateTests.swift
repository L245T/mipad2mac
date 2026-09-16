import Testing
@testable import MiPadCore
struct InputRateTests {
    @Test func windowRatesAndResetFiltering() {
        var m = InputRateMeasurement(start: 10, duration: 2)
        let a = Sample(x: 0.2, y: 0.3, touching: true, inRange: true)
        m.receive(at: 9, sample: a)
        m.receive(at: 10, sample: a)
        m.receive(at: 10.1, sample: a)
        m.receive(at: 10.3, sample: Sample(x: 0.3, y: 0.3, touching: true, inRange: true))
        m.receive(at: 11, sample: Sample(x: 0, y: 1, touching: false, inRange: true, positionValid: false))
        m.receive(at: 12, sample: a)
        m.recordPost(at: 10); m.recordPost(at: 12)
        #expect(m.reports == 4 && m.validPositions == 3 && m.positionChanges == 1)
        #expect(m.resetReports == 1 && m.posted == 1)
        #expect(m.reportRate == 2 && m.positionRate == 1.5 && m.postRate == 0.5)
        #expect(abs(m.maxGap - 0.7) < 0.00001)
    }
    @Test func noInputProducesZeroNotInventedRate() {
        let m = InputRateMeasurement(start: 0)
        #expect(m.reportRate == 0 && m.maxGap == 0)
    }
}
