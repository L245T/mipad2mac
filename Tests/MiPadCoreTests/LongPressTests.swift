import Foundation
import CoreGraphics
import Testing
@testable import MiPadCore

private let screen = Mapping(bounds: CGRect(x: -100, y: 20, width: 1001, height: 1001))
private func pen(_ x: Double = 0.5, _ y: Double = 0.5, down: Bool = true, inRange: Bool = true, valid: Bool = true) -> Sample {
    Sample(x: x, y: y, touching: down, inRange: inRange, pressure: 4096, tiltX: 30, tiltY: -20, positionValid: valid)
}
private func feed(_ g: inout LongPressGesture, _ s: Sample, time: Double = 0, enabled: Bool = true, delay: Double = 0.6, drawing: Bool = false) -> [PointerEvent] {
    g.consume(s, mapping: screen, now: time, enabled: enabled, delay: delay, drawing: drawing)
}

@Test func deferredTapUsesPressPositionEvenOnResetLift() {
    var g = LongPressGesture()
    #expect(feed(&g, pen()).isEmpty)
    let events = feed(&g, pen(0, 1, down: false, valid: false), time: 0.2)
    #expect(events.map(\.action) == [.down, .up])
    #expect(events.allSatisfy { $0.point == CGPoint(x: 400, y: 520) })
    #expect(g.fire(now: 1).isEmpty)
    // A second tap starts a fresh contact; click-count grouping remains in PointerOutput.
    #expect(feed(&g, pen(), time: 0.25).isEmpty)
    #expect(feed(&g, pen(down: false), time: 0.3).map(\.action) == [.down, .up])
}

@Test func jitterIsDistanceFromOriginAndRightClickOccursOnce() {
    var g = LongPressGesture()
    _ = feed(&g, pen(), drawing: true)
    for index in 1...50 {
        #expect(feed(&g, pen(index.isMultiple(of: 2) ? 0.502 : 0.498), time: Double(index) / 100, drawing: true).isEmpty)
    }
    #expect(g.fire(now: 0.599).isEmpty)
    let right = g.fire(now: 0.6)
    #expect(right.map(\.action) == [.rightDown, .rightUp])
    #expect(right.allSatisfy { $0.point == CGPoint(x: 400, y: 520) })
    #expect(g.fire(now: 2).isEmpty)
    let motion = feed(&g, pen(0.8), time: 3)
    #expect(motion == [PointerEvent(action: .move, point: CGPoint(x: 700, y: 520))])
    #expect(feed(&g, pen(0, 1, down: false, valid: false), time: 4).isEmpty)
    #expect(g.isIdle)
}

@Test func movingCancelsLongPressForWholeContact() {
    var g = LongPressGesture()
    _ = feed(&g, pen())
    let events = feed(&g, pen(0.505), time: 0.2)
    #expect(events.map(\.action) == [.down, .drag])
    #expect(events[0].point == CGPoint(x: 400, y: 520))
    #expect(events[1].point == CGPoint(x: 405, y: 520))
    #expect(g.fire(now: 5).isEmpty)
    #expect(feed(&g, pen(), time: 6).map(\.action) == [.drag])
    #expect(g.fire(now: 7).isEmpty)
    #expect(feed(&g, pen(0, 1, down: false), time: 8).map(\.action) == [.up])
}

@Test func cancelDoesNotCreateClickOrRestartUntilLift() {
    var g = LongPressGesture()
    _ = feed(&g, pen())
    #expect(g.cancel().isEmpty)
    #expect(g.fire(now: 2).isEmpty)
    #expect(feed(&g, pen(), time: 3).isEmpty)
    #expect(feed(&g, pen(down: false), time: 4).isEmpty)
    #expect(g.isIdle)
    _ = feed(&g, pen(), time: 5)
    #expect(g.fire(now: 5.6).map(\.action) == [.rightDown, .rightUp])
}

@Test func cancelReleasesDragOnceAndDisconnectResetAcceptsNewContact() {
    var g = LongPressGesture()
    _ = feed(&g, pen()); _ = feed(&g, pen(0.51))
    #expect(g.cancel() == [PointerEvent(action: .up, point: CGPoint(x: 410, y: 520))])
    #expect(g.cancel().isEmpty)
    g.reset()
    #expect(feed(&g, pen(), time: 2).isEmpty)
    #expect(g.fire(now: 2.6).map(\.action) == [.rightDown, .rightUp])
}

@Test func excludedDrawingKeepsImmediateAndUnfilteredEvents() {
    var g = LongPressGesture()
    #expect(feed(&g, pen(), enabled: false, drawing: true).map(\.action) == [.down])
    let events = feed(&g, pen(0.5001), time: 3, enabled: false, drawing: true)
    #expect(events.map(\.action) == [.drag])
    #expect(abs(events[0].point.x - 400.1) < 0.00001)
    #expect(g.fire(now: 10).isEmpty)
    #expect(g.cancel().map(\.action) == [.up])
    #expect(g.cancel().isEmpty)
}

@Test func rangeLossAndInvalidContactCancelPendingTap() {
    for sample in [pen(inRange: false), pen(valid: false), Sample(x: 0.5, y: 0.5, touching: true, inRange: true, eraser: true)] {
        var g = LongPressGesture()
        _ = feed(&g, pen())
        #expect(feed(&g, sample, time: 0.2).isEmpty)
        #expect(g.fire(now: 2).isEmpty)
        #expect(feed(&g, pen(down: false), time: 3).isEmpty)
    }
}

@Test func customDelayAndPreferenceRestoration() throws {
    let suite = "LongPressTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = LongPressPreferences(defaults: defaults)
    #expect(settings.delay == 0.6)
    #expect(settings.enabled)
    #expect(settings.excludes("com.adobe.Photoshop"))
    #expect(settings.excludes("com.adobe.Photoshop.beta"))
    #expect(!settings.excludes("com.adobe.PhotoshopOther"))
    settings.delay = .nan; #expect(settings.delay == 0.6)
    settings.delay = -.infinity; #expect(settings.delay == 0.6)
    settings.delay = -1; #expect(settings.delay == 0.3)
    settings.delay = 5; #expect(settings.delay == 2)
    settings.delay = 1.2; settings.enabled = false
    settings.exclusions = ["example.draw": "Drawing app"]
    let restored = LongPressPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(restored.delay == 1.2)
    #expect(!restored.enabled)
    #expect(restored.excludes("example.draw"))
    var g = LongPressGesture()
    _ = feed(&g, pen(), time: 1, delay: restored.delay)
    #expect(g.fire(now: 2.19).isEmpty)
    #expect(g.fire(now: 2.2).map(\.action) == [.rightDown, .rightUp])
}

@Test func completedLongPressTracksWithoutClicksAndNewContactCanTap() {
    var g = LongPressGesture()
    _ = feed(&g, pen()); _ = g.fire(now: 0.6)
    for x in [0.6, 0.7, 0.5] {
        #expect(feed(&g, pen(x), time: 1).map(\.action) == [.move])
        #expect(g.fire(now: 2).isEmpty)
    }
    #expect(feed(&g, pen(0.5, down: false), time: 3).map(\.action) == [.move])
    #expect(g.isIdle)
    _ = feed(&g, pen(), time: 4)
    #expect(feed(&g, pen(down: false), time: 4.1).map(\.action) == [.down, .up])
}
