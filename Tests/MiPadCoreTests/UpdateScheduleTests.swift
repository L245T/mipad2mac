import Foundation
import Testing
@testable import MiPadCore

struct UpdateScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func chosenIntervalsAndSuccessfulNoUpdateCadence() {
        for interval in UpdateInterval.allCases {
            var s = UpdateSchedule(enabled: true, interval: interval, channel: .stable)
            let token = s.begin(manual: false, now: now)!
            let accepted = s.complete(token, outcome: .success, now: now)
            #expect(accepted)
            #expect(s.nextDue(now: now) == now.addingTimeInterval(interval.seconds))
            #expect(s.begin(manual: false, now: now.addingTimeInterval(interval.seconds - 1)) == nil)
            #expect(s.begin(manual: false, now: now.addingTimeInterval(interval.seconds)) != nil)
        }
    }
    @Test func defaultOffManualBypassAndSingleFlight() {
        var s = UpdateSchedule(enabled: false, interval: .monthly, channel: .stable)
        #expect(s.nextDue(now: now) == nil && s.begin(manual: false, now: now) == nil)
        let token = s.begin(manual: true, now: now)!
        #expect(s.begin(manual: true, now: now) == nil)
        _ = s.complete(token, outcome: .success, now: now)
        #expect(s.begin(manual: true, now: now.addingTimeInterval(1)) != nil)
    }
    @Test func failureIsNotSuccessAndCooldownRespectsServerAndCadence() {
        var s = UpdateSchedule(enabled: true, interval: .monthly, channel: .stable)
        let token = s.begin(manual: false, now: now)!
        _ = s.complete(token, outcome: .failure(retryAfter: now.addingTimeInterval(10 * 3_600)), now: now)
        #expect(s.histories["stable"]?.lastSuccess == nil)
        #expect(s.nextDue(now: now) == now.addingTimeInterval(10 * 3_600))
        #expect(s.begin(manual: true, now: now.addingTimeInterval(1)) == nil)
        let retry = s.begin(manual: false, now: now.addingTimeInterval(10 * 3_600))!
        _ = s.complete(retry, outcome: .success, now: now)
        let manual = s.begin(manual: true, now: now.addingTimeInterval(1))!
        _ = s.complete(manual, outcome: .failure(retryAfter: nil), now: now.addingTimeInterval(1))
        #expect(s.nextDue(now: now) == now.addingTimeInterval(UpdateInterval.monthly.seconds))
    }
    @Test func missedIntervalsCoalesceAndPeriodSwitchUsesLastSuccess() {
        var s = UpdateSchedule(enabled: true, interval: .monthly, channel: .stable, histories: ["stable": UpdateCheckHistory(lastSuccess: now)])
        s.configure(enabled: true, interval: .daily, channel: .stable)
        let wake = now.addingTimeInterval(90 * 86_400)
        let token = s.begin(manual: false, now: wake)!
        #expect(s.begin(manual: false, now: wake) == nil)
        _ = s.complete(token, outcome: .success, now: wake)
        #expect(s.nextDue(now: wake) == wake.addingTimeInterval(86_400))
    }
    @Test func channelAndDisabledBackgroundInvalidateOldCallback() {
        var s = UpdateSchedule(enabled: true, interval: .daily, channel: .stable)
        let old = s.begin(manual: false, now: now)!
        #expect(s.configure(enabled: true, interval: .daily, channel: .beta) == old)
        let new = s.begin(manual: false, now: now)!
        let acceptedOld = s.complete(old, outcome: .success, now: now)
        #expect(!acceptedOld)
        #expect(s.active == new && s.histories["stable"] == nil)
        let cancelled = s.configure(enabled: false, interval: .daily, channel: .beta)
        #expect(cancelled == new)
        let acceptedNew = s.complete(new, outcome: .success, now: now)
        #expect(!acceptedNew)
    }
    @Test func backClockCannotStrandChecksAndHistoryIsIndependentPerChannel() {
        var s = UpdateSchedule(enabled: true, interval: .daily, channel: .stable,
            histories: ["stable": UpdateCheckHistory(lastSuccess: now.addingTimeInterval(365 * 86_400)), "beta": UpdateCheckHistory(lastSuccess: now.addingTimeInterval(-86_400))])
        s.normalizeClock(now: now)
        #expect(s.nextDue(now: now) == now.addingTimeInterval(86_400))
        s.configure(enabled: true, interval: .daily, channel: .beta)
        #expect(s.begin(manual: false, now: now) != nil)
    }
    @Test func migrationPreservesOldChoiceWithoutInventingSuccess() {
        let suite = "MiPadScheduleTests." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!; defer { d.removePersistentDomain(forName: suite) }
        #expect(!d.bool(forKey: "checkUpdatesAutomatically"))
        #expect(UpdateSchedulePreferences.interval(in: d) == .daily)
        d.set(true, forKey: "checkUpdatesAutomatically"); d.set(now.timeIntervalSince1970, forKey: "lastUpdateCheck")
        let history = UpdateSchedulePreferences.histories(in: d)
        #expect(history["stable"]?.lastSuccess == nil && history["stable"]?.legacyLastAttempt == now)
        UpdateSchedulePreferences.save(history, in: d)
        d.set(0, forKey: "lastUpdateCheck")
        #expect(UpdateSchedulePreferences.histories(in: d) == history)
        #expect(d.bool(forKey: "checkUpdatesAutomatically"))
        d.set(7, forKey: UpdateSchedulePreferences.intervalKey)
        #expect(UpdateSchedulePreferences.interval(in: d) == .weekly)
    }
    @Test func retryAfterSecondsHTTPDateAndInvalidHeaders() {
        #expect(HTTPRetryAfter.date("7200", now: now) == now.addingTimeInterval(7200))
        let d = HTTPRetryAfter.date("Wed, 21 Oct 2037 07:28:00 GMT", now: now)
        #expect(d != nil && d! > now)
        for header in [nil, "", "-1", "NaN", "bad"] as [String?] { #expect(HTTPRetryAfter.date(header, now: now) == nil) }
    }
}
