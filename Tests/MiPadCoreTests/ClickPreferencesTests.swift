import Foundation
import Testing
@testable import MiPadCore

@Test func clickJitterPreferencesPersistSeparatelyFromLongPress() {
    let name = "MiPadCore-click-jitter-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = ClickPreferences(defaults: defaults)
    #expect(settings.jitterTolerance == 4)
    LongPressPreferences(defaults: defaults).jitterFilter = .medium
    for value in [0.0, 2, 4, 8, 18] {
        settings.jitterTolerance = value
        #expect(ClickPreferences(defaults: defaults).jitterTolerance == value)
        #expect(LongPressPreferences(defaults: defaults).jitterFilter == .medium)
    }
    settings.jitterTolerance = 100; #expect(settings.jitterTolerance == 18)
    settings.jitterTolerance = -1; #expect(settings.jitterTolerance == 0)
    settings.jitterTolerance = 6.7; #expect(settings.jitterTolerance == 7)
    settings.jitterTolerance = .nan; #expect(settings.jitterTolerance == 4)
    defaults.set("bad", forKey: "penMultiClickJitterTolerance")
    #expect(settings.jitterTolerance == 4)
}
