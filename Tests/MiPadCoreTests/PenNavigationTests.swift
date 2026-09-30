import Foundation
import CoreGraphics
import Testing
@testable import MiPadCore

private func penAt(_ x: Double = 0.5, _ y: Double = 0.5, down: Bool = true,
                   range: Bool = true, valid: Bool = true) -> Sample {
    Sample(x: x, y: y, touching: down, inRange: range, pressure: 4096,
           tiltX: 30, tiltY: -20, positionValid: valid)
}
private let browseScreen = Mapping(bounds: CGRect(x: -1000, y: -500, width: 1001, height: 1001))
private func browse(_ gesture: inout LongPressGesture, _ sample: Sample,
                    enabled: Bool = true, mapping: Mapping = browseScreen) -> PenGestureEvents {
    gesture.consumeNavigation(sample, mapping: mapping, now: 0, enabled: enabled,
                delay: 0.6, drawing: true, navigation: .browse)
}

@Test func browseTapAndLongPressRemainExclusive() {
    var gesture = LongPressGesture()
    #expect(browse(&gesture, penAt()).pointer.isEmpty)
    #expect(browse(&gesture, penAt(0.503, 0.502)).scroll.isEmpty)
    let tap = browse(&gesture, penAt(0, 1, down: false, valid: false))
    #expect(tap.pointer.map(\.action) == [.down, .up])
    #expect(tap.pointer.allSatisfy { $0.point == CGPoint(x: -500, y: 0) })
    #expect(tap.scroll.isEmpty)
    _ = browse(&gesture, penAt())
    #expect(gesture.fire(now: 0.6, compatibility: true).map(\.action) == [.rightDown, .rightUp])
    #expect(gesture.fire(now: 0.7).map(\.action) == [.rightDown, .rightUp])
    #expect(browse(&gesture, penAt(0.8, 0.8)).scroll.isEmpty)
    #expect(browse(&gesture, penAt(down: false)).pointer.allSatisfy { $0.action == .move })
}

@Test func scrollNeverPostsLeftButtonsAndUsesFixedAnchor() {
    var gesture = LongPressGesture()
    _ = browse(&gesture, penAt())
    let begin = browse(&gesture, penAt(0.502, 0.51))
    #expect(begin.pointer.isEmpty)
    #expect(begin.scroll == [PenScrollEvent(anchor: CGPoint(x: -500, y: 0), phase: .began, vertical: 10)])
    #expect(gesture.fire(now: 5).isEmpty)
    let change = browse(&gesture, penAt(0.8, 0.54))
    #expect(change.pointer.isEmpty)
    #expect(change.scroll.first?.anchor == begin.scroll.first?.anchor)
    #expect(change.scroll.first?.horizontal == 0)
    let end = browse(&gesture, penAt(0, 1, down: false, valid: false))
    #expect(end.pointer.isEmpty)
    #expect(end.scroll.first?.phase == .ended)
    #expect(gesture.isIdle)
}

@Test func browseWorksWithoutLongPressAndLocksModeForContact() {
    var gesture = LongPressGesture()
    _ = browse(&gesture, penAt(), enabled: false)
    #expect(!gesture.hasScheduledClick)
    let result = gesture.consumeNavigation(penAt(0.53), mapping: browseScreen, now: 1,
                       enabled: false, delay: 0.6, drawing: true, navigation: .pointer)
    #expect(result.pointer.isEmpty)
    #expect(result.scroll.first?.horizontal == 30)
    #expect(result.scroll.first?.vertical == 0)
}

@Test func scrollCancellationSuppressesRestOfContact() {
    for invalid in [penAt(valid: false), penAt(range: false)] {
        var gesture = LongPressGesture()
        _ = browse(&gesture, penAt()); _ = browse(&gesture, penAt(0.5, 0.52))
        let cancelled = browse(&gesture, invalid)
        #expect(cancelled.pointer.isEmpty)
        #expect(cancelled.scroll.first?.phase == .cancelled)
        #expect(browse(&gesture, penAt(0.6, 0.6)).scroll.isEmpty)
        _ = browse(&gesture, penAt(down: false))
        #expect(gesture.isIdle)
    }
    var gesture = LongPressGesture()
    _ = browse(&gesture, penAt()); _ = browse(&gesture, penAt(0.5, 0.52))
    #expect(gesture.cancelNavigation().scroll.first?.phase == .cancelled)
    #expect(browse(&gesture, penAt(0.6, 0.6)).pointer.isEmpty)
    #expect(gesture.cancelNavigation().scroll.isEmpty)
    gesture.reset()
    _ = browse(&gesture, penAt()); #expect(browse(&gesture, penAt(down: false)).pointer.count == 2)
}

@Test func scrollAccumulatesSubpixelMovementAndReversal() {
    var gesture = LongPressGesture()
    _ = browse(&gesture, penAt())
    var total = Int32(0)
    for index in 0...100 {
        let result = browse(&gesture, penAt(0.5, 0.51 + Double(index) * 0.0001))
        total += result.scroll.reduce(0) { $0 + $1.vertical }
    }
    #expect(abs(total - 20) <= 1)
    let reverse = browse(&gesture, penAt(0.5, 0.49))
    #expect(reverse.scroll.first?.vertical ?? 0 < 0)
}

@Test func scrollUsesRotatedFlippedLogicalCoordinates() {
    for rotation in [0, 90, 180, 270] {
        for flipX in [false, true] {
            for flipY in [false, true] {
                var gesture = LongPressGesture()
                let mapping = Mapping(bounds: browseScreen.bounds, rotation: rotation, flipX: flipX, flipY: flipY)
                _ = browse(&gesture, penAt(), mapping: mapping)
                let next = browse(&gesture, penAt(0.5, 0.52), mapping: mapping)
                let origin = mapping.point(x: 0.5, y: 0.5), end = mapping.point(x: 0.5, y: 0.52)
                #expect(next.scroll.first?.anchor == origin)
                #expect(next.scroll.first?.vertical == Int32((end.y - origin.y).rounded()))
                #expect(next.scroll.first?.horizontal == Int32((end.x - origin.x).rounded()))
                #expect(next.pointer.isEmpty)
            }
        }
    }
}

@Test func navigationPreferencesPersistAndExclusionWins() throws {
    let suite = "navigation-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = PenNavigationPreferences(defaults: defaults)
    #expect(preferences.mode(for: nil) == .pointer)
    #expect(preferences.mode(for: "unknown") == .pointer)
    preferences.set(.browse, for: "com.google.Chrome", name: "Chrome")
    let restored = PenNavigationPreferences(defaults: defaults)
    #expect(restored.mode(for: "COM.GOOGLE.CHROME") == .browse)
    #expect(restored.mode(for: "com.google.Chrome", excluded: true) == .pointer)
    #expect(restored.applications["com.google.Chrome"] == "Chrome")
    #expect(restored.hasBrowseApplications)
    defaults.set(["com.google.chrome": "corrupt"], forKey: "penNavigationApplicationModes")
    #expect(restored.mode(for: "com.google.Chrome") == .pointer)
}

@Test func invalidPositionEndsImmediateDrawingWithoutJump() {
    var gesture = LongPressGesture()
    _ = gesture.consume(penAt(), mapping: browseScreen, now: 0, enabled: false, delay: 0.6, drawing: true)
    let end = gesture.consume(penAt(0, 1, valid: false), mapping: browseScreen, now: 1, enabled: false, delay: 0.6, drawing: true)
    #expect(end == [PointerEvent(action: .up, point: CGPoint(x: -500, y: 0))])
    #expect(gesture.consume(penAt(), mapping: browseScreen, now: 2, enabled: false, delay: 0.6, drawing: true).isEmpty)
}
