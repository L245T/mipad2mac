import Foundation
import CoreGraphics
import Testing
@testable import MiPadCore

@Test func buttonRadiusPersistsIndependentlyAndRejectsMalformedValues() {
    let suite = "button-tolerance-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ButtonTargetTolerancePreferences(defaults: defaults)
    #expect(preferences.radius == 6)
    defaults.set(12, forKey: "penMultiClickJitterTolerance")
    defaults.set("high", forKey: "penLongPressJitterFilter")
    preferences.radius = 0
    #expect(ButtonTargetTolerancePreferences(defaults: UserDefaults(suiteName: suite)!).radius == 0)
    #expect(ClickPreferences(defaults: defaults).jitterTolerance == 12)
    #expect(LongPressPreferences(defaults: defaults).jitterFilter == .high)
    preferences.radius = 30; #expect(preferences.radius == 18)
    preferences.radius = -2; #expect(preferences.radius == 0)
    preferences.radius = 6.6; #expect(preferences.radius == 7)
    preferences.radius = .nan; #expect(preferences.radius == 6)
    for invalid: Any in [true, "18", [1, 2]] {
        defaults.set(invalid, forKey: "penButtonTargetRadius")
        #expect(preferences.radius == 6)
    }
}
@Test func nearestButtonUsesEdgeDistanceAndRequiresCompleteEnumeration() {
    let point = CGPoint.zero
    let wide = CGRect(x: 3, y: -10, width: 100, height: 20)
    let narrow = CGRect(x: -10, y: 5, width: 20, height: 20)
    #expect(ButtonTargetGeometry.nearest(to: point, radius: 6, frames: [wide, narrow], complete: true) == 0)
    #expect(ButtonTargetGeometry.nearest(to: point, radius: 6, frames: [wide], complete: false) == nil)
    #expect(ButtonTargetGeometry.nearest(to: point, radius: 0, frames: [wide], complete: true) == nil)
    #expect(ButtonTargetGeometry.nearest(to: point, radius: .infinity, frames: [wide], complete: true) == nil)
    #expect(ButtonTargetGeometry.nearest(to: point, radius: 2.99, frames: [wide], complete: true) == nil)
    #expect(ButtonTargetGeometry.nearest(to: point, radius: 3, frames: [wide], complete: true) == 0)
    #expect(ButtonTargetGeometry.clickPoint(from: point, inside: wide) == CGPoint(x: 4, y: 0))
}
@Test func ambiguousAndInvalidButtonGeometryDoesNotSelectAnArbitraryTarget() {
    let left = CGRect(x: -24, y: -10, width: 20, height: 20)
    let right = CGRect(x: 4, y: -10, width: 20, height: 20)
    for frames in [[left, right], [right, left]] {
        #expect(ButtonTargetGeometry.nearest(to: .zero, radius: 18, frames: frames, complete: true) == nil)
    }
    #expect(ButtonTargetGeometry.nearest(to: .zero, radius: 18,
        frames: [.zero, .null, CGRect(x: 2, y: 0, width: 40, height: 40)], complete: true) == nil)
    #expect(ButtonTargetGeometry.nearest(to: CGPoint(x: CGFloat.nan, y: 0), radius: 18, frames: [right], complete: true) == nil)
    #expect(ButtonTargetGeometry.nearest(to: CGPoint(x: 5, y: 0), radius: 18, frames: [right], complete: true) == nil)
    #expect(ButtonTargetGeometry.nearest(to: .zero, radius: 18, frames: [.zero, right], complete: true) == nil)
    #expect(ButtonTargetGeometry.nearest(to: CGPoint(x: 5, y: 0), radius: 18, frames: [right, left], complete: true) == nil)
    #expect(ButtonTargetGeometry.distance(from: CGPoint(x: -1925, y: 10),
        to: CGRect(x: -1920, y: 0, width: 20, height: 20)) == 5)
    #expect(ButtonTargetGeometry.distance(from: .zero, to: CGRect(x: 3, y: 4, width: 20, height: 20)) == 5)
}
@Test func textControlsAndWindowChromeRemainProtectedFromButtonMissAssistance() {
    #expect(ButtonTargetGeometry.permitsMiss(roles: ["AXGroup", "AXWindow"]))
    #expect(!ButtonTargetGeometry.permitsMiss(roles: []))
    for role in ["AXStaticText", "AXButton", "AXTextArea", "AXTextField", "AXLink", "AXSlider", "AXMenuItem", "AXTitleBar"] {
        #expect(!ButtonTargetGeometry.permitsMiss(roles: [role, "AXWindow"]))
        #expect(!ButtonTargetGeometry.permitsMiss(roles: ["AXGroup", role, "AXWindow"]))
    }
}
@Test func windowButtonMissAllowsTitlebarButProtectsContentHits() {
    #expect(ButtonTargetGeometry.permitsWindowButtonMiss(roles: ["AXTitleBar", "AXWindow"]))
    #expect(ButtonTargetGeometry.permitsWindowButtonMiss(roles: ["AXGroup", "AXTitleBar", "AXWindow"]))
    #expect(!ButtonTargetGeometry.permitsWindowButtonMiss(roles: []))
    for role in ["AXStaticText", "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXMenuItem", "AXSlider"] {
        #expect(!ButtonTargetGeometry.permitsWindowButtonMiss(roles: [role, "AXTitleBar", "AXWindow"]))
    }
    #expect(!ButtonTargetGeometry.permitsMiss(roles: ["AXTitleBar", "AXWindow"]))
}
private let buttonMapping = Mapping(bounds: CGRect(x: 0, y: 0, width: 101, height: 101))
private func buttonSample(_ x: Double = 0.5, touching: Bool = true, inRange: Bool = true) -> Sample {
    Sample(x: x, y: 0.5, touching: touching, inRange: inRange)
}
@Test func buttonOnlyDelayDoesNotEnableRightClickOrChangeDragOrigin() {
    var gesture = LongPressGesture()
    func consume(_ sample: Sample, at time: Double) -> PenGestureEvents {
        gesture.consumeNavigation(sample, mapping: buttonMapping, now: time, enabled: false,
            delay: 0.3, drawing: false, jitterFilter: .maximum, deferButtonTap: true)
    }
    #expect(consume(buttonSample(), at: 0).pointer.isEmpty)
    #expect(gesture.deadline == nil)
    #expect(gesture.fire(now: 1).isEmpty)
    #expect(consume(buttonSample(0.53), at: 0.02).pointer.isEmpty)
    let drag = consume(buttonSample(0.55), at: 0.03)
    #expect(drag.pointer.map { $0.action } == [.down, .drag])
    #expect(drag.pointer.first?.point == CGPoint(x: 50, y: 50))
    #expect(!drag.completedTap)
    let lift = consume(buttonSample(touching: false), at: 0.04)
    #expect(lift.pointer.map { $0.action } == [.up])
    #expect(!lift.completedTap)
}
@Test func onlyAnUncancelledPendingLiftIsEligibleForButtonAssistance() {
    var gesture = LongPressGesture()
    func consume(_ sample: Sample, at time: Double, deferTap: Bool = true) -> PenGestureEvents {
        gesture.consumeNavigation(sample, mapping: buttonMapping, now: time, enabled: false,
            delay: 0.3, drawing: false, deferButtonTap: deferTap)
    }
    _ = consume(buttonSample(), at: 0)
    let tap = consume(buttonSample(touching: false), at: 0.05)
    #expect(tap.completedTap && tap.pointer.map { $0.action } == [.down, .up])
    _ = consume(buttonSample(), at: 1)
    #expect(gesture.cancelNavigation().pointer.isEmpty)
    #expect(!consume(buttonSample(touching: false), at: 1.1).completedTap)
    #expect(consume(buttonSample(), at: 2, deferTap: false).pointer.map { $0.action } == [.down])
    #expect(!consume(buttonSample(touching: false), at: 2.1, deferTap: false).completedTap)
}
@Test func buttonDelayLeavesBrowseScrollAndLongPressOnPhysicalCoordinates() {
    var gesture = LongPressGesture()
    func consume(_ sample: Sample, at time: Double, enabled: Bool = false) -> PenGestureEvents {
        gesture.consumeNavigation(sample, mapping: buttonMapping, now: time, enabled: enabled,
            delay: 0.3, drawing: false, navigation: .browse, deferButtonTap: true)
    }
    _ = consume(buttonSample(), at: 0)
    let scroll = consume(buttonSample(0.7), at: 0.1)
    #expect(scroll.scroll.first?.anchor == CGPoint(x: 50, y: 50))
    #expect(scroll.pointer.allSatisfy { $0.action == .move })
    #expect(!consume(buttonSample(touching: false), at: 0.2).completedTap)
    _ = consume(buttonSample(), at: 1, enabled: true)
    let right = gesture.fire(now: 1.4)
    #expect(right.map { $0.action } == [.rightDown, .rightUp])
    #expect(right.allSatisfy { $0.point == CGPoint(x: 50, y: 50) })
    #expect(!consume(buttonSample(touching: false), at: 1.5).completedTap)
}
