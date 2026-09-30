import CoreGraphics
import Testing
@testable import MiPadCore

@Test func successiveClicksCarryMatchingNativeCounts() {
    var sequence = ClickSequence()
    for index in 0..<4 {
        let time = Double(index) * 0.15
        #expect(sequence.begin(at: .zero, now: time, interval: 0.5) == Int64(index + 1))
        sequence.end(now: time + 0.1, interval: 0.5)
    }
}
@Test func selectionIntentPreviewDoesNotConsumeClickSequence() {
    var sequence = ClickSequence()
    #expect(sequence.nextCount(at: .zero, now: 0, interval: 0.5) == 1)
    _ = sequence.begin(at: .zero, now: 0, interval: 0.5)
    sequence.end(now: 0.05, interval: 0.5)
    for _ in 0..<3 { #expect(sequence.nextCount(at: .zero, now: 0.1, interval: 0.5) == 2) }
    #expect(sequence.nextCount(at: CGPoint(x: 20, y: 0), now: 0.1, interval: 0.5) == 1)
    #expect(sequence.nextCount(at: .zero, now: 1, interval: 0.5) == 1)
    #expect(sequence.begin(at: .zero, now: 0.1, interval: 0.5) == 2)
    sequence.drag(to: CGPoint(x: 20, y: 0)); sequence.end(now: 0.15, interval: 0.5)
    #expect(sequence.nextCount(at: .zero, now: 0.2, interval: 0.5) == 1)
}
@Test func clickTimeAndDistanceBoundariesUsePhysicalPress() {
    var sequence = ClickSequence()
    #expect(sequence.begin(at: .zero, now: 0, interval: 0.5) == 1)
    sequence.end(now: 0.4, interval: 0.5)
    // The previous release was recent, but the two physical presses exceed the system interval.
    #expect(sequence.begin(at: .zero, now: 0.6, interval: 0.5) == 1)
    sequence.end(now: 0.61, interval: 0.5)
    #expect(sequence.begin(at: CGPoint(x: 5, y: 0), now: 0.7, interval: 0.5) == 1)
    sequence.end(now: 0.71, interval: 0.5)
    #expect(sequence.begin(at: CGPoint(x: 5, y: 0), now: 1.2, interval: 0.5) == 1)
}
@Test func doubleClickDragKeepsActiveCountButResetsNextTap() {
    var sequence = ClickSequence()
    _ = sequence.begin(at: .zero, now: 0, interval: 0.5)
    sequence.end(now: 0.05, interval: 0.5)
    #expect(sequence.begin(at: .zero, now: 0.1, interval: 0.5) == 2)
    sequence.drag(to: CGPoint(x: 40, y: 0))
    sequence.end(now: 0.15, interval: 0.5)
    #expect(sequence.begin(at: .zero, now: 0.2, interval: 0.5) == 1)
}
@Test func stationaryPressureDoesNotCountAsSelectionDrag() {
    var sequence = ClickSequence()
    _ = sequence.begin(at: .zero, now: 0, interval: 0.5)
    sequence.drag(to: .zero)
    sequence.end(now: 0.05, interval: 0.5)
    #expect(sequence.begin(at: CGPoint(x: 1, y: 1), now: 0.1, interval: 0.5) == 2)
}
@Test func cancellationLongHoldAndClockResetBreakClickSequence() {
    var sequence = ClickSequence()
    _ = sequence.begin(at: .zero, now: 0, interval: 0.5)
    sequence.end(now: 0.05, interval: 0.5)
    sequence.reset()
    #expect(sequence.begin(at: .zero, now: 0.1, interval: 0.5) == 1)
    sequence.end(now: 2, interval: 0.5)
    #expect(sequence.begin(at: .zero, now: 2.1, interval: 0.5) == 1)
    sequence.end(now: 2.2, interval: 0.5)
    #expect(sequence.begin(at: .zero, now: 1, interval: 0.5) == 1)
}
@Test func spatialJitterAllowsOffsetClicksAndSmallContactMovement() {
    var sequence = ClickSequence()
    #expect(sequence.begin(at: .zero, now: 0, interval: 0.5, extraTolerance: 4) == 1)
    sequence.drag(to: CGPoint(x: 6, y: 0))
    sequence.end(now: 0.05, interval: 0.5)
    #expect(sequence.begin(at: CGPoint(x: 6, y: 0), now: 0.1, interval: 0.5, extraTolerance: 4) == 2)
    sequence.end(now: 0.15, interval: 0.5)
    #expect(sequence.nextCount(at: CGPoint(x: 8, y: 0), now: 0.2, interval: 0.5, extraTolerance: 4) == 3)
    #expect(sequence.begin(at: CGPoint(x: 8, y: 0), now: 0.2, interval: 0.5, extraTolerance: 4) == 3)
    sequence.drag(to: CGPoint(x: 16, y: 0)); sequence.end(now: 0.25, interval: 0.5)
    #expect(sequence.nextCount(at: CGPoint(x: 8, y: 0), now: 0.3, interval: 0.5, extraTolerance: 4) == 1)
}
@Test func jitterNeverChainsAcrossGrowingDistanceOrExtendsTimeLimit() {
    var sequence = ClickSequence()
    _ = sequence.begin(at: .zero, now: 0, interval: 0.5, extraTolerance: 4)
    sequence.end(now: 0.05, interval: 0.5)
    #expect(sequence.nextCount(at: CGPoint(x: 9, y: 0), now: 0.1, interval: 0.5, extraTolerance: 4) == 1)
    _ = sequence.begin(at: CGPoint(x: 6, y: 0), now: 0.1, interval: 0.5, extraTolerance: 4)
    sequence.end(now: 0.15, interval: 0.5)
    #expect(sequence.nextCount(at: CGPoint(x: 12, y: 0), now: 0.2, interval: 0.5, extraTolerance: 4) == 1)
    #expect(sequence.nextCount(at: CGPoint(x: 6, y: 0), now: 0.6, interval: 0.5, extraTolerance: 18) == 1)
    // Disabled tolerance and drawing retain the original per-tap distance behavior.
    sequence.reset()
    for index in 0..<3 {
        let time = Double(index) * 0.1
        #expect(sequence.begin(at: CGPoint(x: Double(index) * 3, y: 0), now: time, interval: 0.5) == Int64(index + 1))
        sequence.end(now: time + 0.05, interval: 0.5)
    }
}
