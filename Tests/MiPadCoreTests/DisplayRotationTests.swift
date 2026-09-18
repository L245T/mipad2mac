import Foundation
import CoreGraphics
import Testing
@testable import MiPadCore

@Test func systemRotationResolvesQuarterTurnsWithoutAddingManualAngle() {
    for angle in [0, 90, 180, 270] {
        #expect(DisplayRotationMode.system.angle(systemAngle: Double(angle)) == angle)
        for mode in DisplayRotationMode.allCases where mode != .system {
            #expect(mode.angle(systemAngle: Double(angle)) == mode.rawValue)
        }
    }
    #expect(DisplayRotationMode.system.angle(systemAngle: -90) == 270)
    #expect(DisplayRotationMode.system.angle(systemAngle: 450) == 90)
    #expect(DisplayRotationMode.system.angle(systemAngle: 89.999999) == 90)
    for invalid in [Double.nan, .infinity, -.infinity, 45, 89.5] {
        #expect(DisplayRotationMode.system.angle(systemAngle: invalid) == 0)
    }
}

@Test func rotatedPortraitMappingMatchesManualCorrectionAndTilt() {
    let bounds = CGRect(x: 1800, y: 78, width: 1136, height: 1704)
    let automatic = Mapping(bounds: bounds, rotation: DisplayRotationMode.system.angle(systemAngle: 90))
    #expect(automatic.point(x: 0, y: 0) == CGPoint(x: 2935, y: 78))
    #expect(automatic.point(x: 1, y: 1) == CGPoint(x: 1800, y: 1781))
    #expect(automatic.tilt(x: 45, y: -45) == CGPoint(x: 0.5, y: 0.5))
    for angle in [0, 90, 180, 270] {
        let auto = Mapping(bounds: bounds, rotation: DisplayRotationMode.system.angle(systemAngle: Double(angle)))
        let manual = Mapping(bounds: bounds, rotation: angle)
        for point in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: 0.25, y: 0.75)] {
            #expect(auto.point(x: point.x, y: point.y) == manual.point(x: point.x, y: point.y))
        }
        #expect(auto.tilt(x: 30, y: -20) == manual.tilt(x: 30, y: -20))
    }
}

@Test func rotationPreferenceRestoresAndInvalidValueUsesSystem() throws {
    let suite = "RotationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = DisplayRotationPreferences(defaults: defaults)
    #expect(prefs.mode == .system)
    for mode in DisplayRotationMode.allCases {
        prefs.mode = mode
        #expect(DisplayRotationPreferences(defaults: defaults).mode == mode)
    }
    for value in [45.0, 90.5, 999] {
        defaults.set(value, forKey: "penDisplayRotationMode")
        #expect(prefs.mode == .system)
    }
    defaults.set("invalid", forKey: "penDisplayRotationMode")
    #expect(prefs.mode == .system)
}
