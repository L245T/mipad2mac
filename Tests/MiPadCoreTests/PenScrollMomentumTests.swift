import Foundation
import Testing
@testable import MiPadCore

private func launched(speed: Double = 800, pressure: Double = 0.5, horizontal: Bool = false) -> PenScrollMomentum {
    var model = PenScrollMomentum()
    model.start(anchor: CGPoint(x: -100, y: 50), axis: horizontal ? .horizontal : .vertical, now: 0)
    for i in 1...8 {
        let t = Double(i) * 0.01
        model.record(CGPoint(x: -100 + (horizontal ? speed * t : 0), y: 50 + (horizontal ? 0 : speed * t)), pressure: pressure, now: t)
    }
    _ = model.lift(now: 0.085, enabled: true)
    return model
}
private func travel(_ original: PenScrollMomentum, rate: Double = 60) -> (Int, [PenMomentumPhase]) {
    var model = original, pixels = 0, phases: [PenMomentumPhase] = []
    for i in 1...Int(rate * 3.2) {
        if let event = model.tick(now: 0.085 + Double(i) / rate) {
            pixels += Int(event.vertical + event.horizontal); phases.append(event.phase)
        }
    }
    return (pixels, phases)
}
struct PenScrollMomentumTests {
    @Test func velocityAndPressureProduceBoundedDecayInBothAxes() {
        let slow = travel(launched(speed: 200)), fast = travel(launched())
        #expect(fast.0 > slow.0 && slow.0 > 0)
        #expect(fast.1.first == .began && fast.1.last == .ended)
        #expect(fast.1.dropFirst().dropLast().allSatisfy { $0 == .changed })
        let soft = travel(launched(pressure: 0)), hard = travel(launched(pressure: 1))
        #expect(hard.0 > soft.0 && Double(hard.0) < Double(soft.0) * 1.5)
        #expect(abs(travel(launched(speed: 100000)).0) <= 2500)
        #expect(travel(launched(speed: -800)).0 == -fast.0)
        #expect(travel(launched(horizontal: true)).0 == fast.0)
        #expect(abs(travel(launched(), rate: 120).0 - travel(launched(), rate: 30).0) <= 3)
    }
    @Test func recentAccelerationPreservesReleaseSpeedAcrossReportRates() {
        func accelerating(rate: Double) -> PenScrollMomentum {
            var model = PenScrollMomentum()
            model.start(anchor: .zero, axis: .vertical, now: 0)
            for i in 1...Int(rate * 0.2) {
                let t = Double(i) / rate
                model.record(CGPoint(x: 0, y: 4000 * t * t), pressure: 0.5, now: t)
            }
            _ = model.lift(now: 0.205, enabled: true)
            return model
        }
        func total(_ original: PenScrollMomentum) -> Int {
            var model = original, result = 0
            for i in 1...384 {
                if let event = model.tick(now: 0.205 + Double(i) / 120) { result += Int(event.vertical) }
            }
            return result
        }
        let dense = total(accelerating(rate: 240)), sparse = total(accelerating(rate: 60))
        #expect(dense > 650 && dense < 800)
        #expect(abs(dense - sparse) < 10)
        // 800 logical points/s now coasts roughly 390 points rather than the old 142.
        let ordinary = travel(launched()).0
        #expect(ordinary > 380 && ordinary < 410)
        #expect(travel(launched(speed: 3000)).0 > 1400)
    }
    @Test func pauseStationaryPressureAndOldSamplesDoNotLaunch() {
        var stopped = PenScrollMomentum()
        stopped.start(anchor: .zero, axis: .vertical, now: 0)
        stopped.record(CGPoint(x: 0, y: 80), pressure: 1, now: 0.05)
        for i in 6...25 { stopped.record(CGPoint(x: 0, y: 80), pressure: 1, now: Double(i) / 100) }
        let result = stopped.lift(now: 0.26, enabled: true)
        #expect(!result && !stopped.isCoasting)
        var still = PenScrollMomentum()
        still.start(anchor: .zero, axis: .vertical, now: 0)
        still.record(.zero, pressure: 1, now: 0.03)
        let stationary = still.lift(now: 0.04, enabled: true)
        #expect(!stationary)
        still.start(anchor: .zero, axis: .vertical, now: 0)
        still.record(CGPoint(x: 0, y: 80), pressure: 1, now: 0.03)
        let stale = still.lift(now: 1, enabled: true)
        #expect(!stale)
    }
    @Test func reversalUsesLatestDirectionAndCancelStopsAllFutureFrames() {
        var model = PenScrollMomentum()
        model.start(anchor: .zero, axis: .vertical, now: 0)
        model.record(CGPoint(x: 0, y: 100), pressure: 0.5, now: 0.03)
        model.record(CGPoint(x: 0, y: 90), pressure: 0.5, now: 0.05)
        model.record(CGPoint(x: 0, y: 60), pressure: 0.5, now: 0.07)
        let began = model.lift(now: 0.075, enabled: true)
        #expect(began)
        let first = model.tick(now: 0.09)
        #expect((first?.vertical ?? 0) < 0)
        let end = model.cancel()
        #expect(end?.phase == .ended && !model.isCoasting)
        let future = model.tick(now: 0.11)
        #expect(future == nil)
        model.start(anchor: .zero, axis: .vertical, now: 1)
        let next = model.lift(now: 1.01, enabled: true)
        #expect(!next)
    }
    @Test func stallDoesNotBurstAndDisabledSettingDoesNotCoast() {
        var model = launched()
        let first = model.tick(now: 0.101)
        let afterStall = model.tick(now: 0.5)
        #expect(first?.phase == .began && afterStall?.phase == .ended)
        #expect(afterStall?.vertical == 0 && !model.isCoasting)
        model.start(anchor: .zero, axis: .vertical, now: 0)
        model.record(CGPoint(x: 0, y: 50), pressure: .nan, now: 0.03)
        let disabled = model.lift(now: 0.04, enabled: false)
        #expect(!disabled)
        let future = model.tick(now: 0.05)
        #expect(future == nil)
    }
    @Test func preferenceDefaultsOnAndRestoresExplicitChoice() throws {
        let suite = "momentum-test-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ScrollMomentumPreferences(defaults: defaults)
        #expect(settings.enabled)
        settings.enabled = false
        #expect(!ScrollMomentumPreferences(defaults: defaults).enabled)
        settings.enabled = true
        #expect(ScrollMomentumPreferences(defaults: defaults).enabled)
    }
}
