import AppKit
import MiPadCore

/// Owns the only update timer and all startup/wake/Retry-After scheduling. Main-thread confined.
final class UpdateScheduler {
    private let defaults: UserDefaults
    let now: () -> Date
    private(set) var state: UpdateSchedule
    var perform: (UpdateRequestToken) -> Void = { _ in }
    var cancelRequest: () -> Void = {}
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        state = UpdateSchedule(enabled: defaults.bool(forKey: "checkUpdatesAutomatically"),
            interval: UpdateSchedulePreferences.interval(in: defaults),
            channel: UpdateChannel(rawValue: defaults.string(forKey: "updateChannel") ?? "") ?? .stable,
            histories: UpdateSchedulePreferences.histories(in: defaults))
        // Persist migration once without changing old users' automatic-check choice.
        defaults.set(state.interval.rawValue, forKey: UpdateSchedulePreferences.intervalKey)
        state.normalizeClock(now: now()); persist()
    }
    func start() {
        guard !started else { return }; started = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.reconcile() })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.timer?.invalidate(); self?.timer = nil })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.reconcile() })
        reconcile()
    }
    func configurationChanged() {
        let cancelled = state.configure(enabled: defaults.bool(forKey: "checkUpdatesAutomatically"),
            interval: UpdateSchedulePreferences.interval(in: defaults),
            channel: UpdateChannel(rawValue: defaults.string(forKey: "updateChannel") ?? "") ?? .stable)
        if cancelled != nil { cancelRequest() }
        reconcile()
    }
    @discardableResult func requestManual() -> Bool {
        let time = now(); state.normalizeClock(now: time)
        guard let token = state.begin(manual: true, now: time) else { return false }
        timer?.invalidate(); timer = nil; perform(token); return true
    }
    func isCurrent(_ token: UpdateRequestToken) -> Bool { state.active == token }
    @discardableResult func complete(_ token: UpdateRequestToken, outcome: UpdateCheckOutcome) -> Bool {
        guard state.complete(token, outcome: outcome, now: now()) else { return false }
        persist(); reconcile(); return true
    }
    func reconcile() {
        timer?.invalidate(); timer = nil
        guard started else { return }
        let time = now(); state.normalizeClock(now: time); persist()
        guard let due = state.nextDue(now: time) else { return }
        if due <= time, let token = state.begin(manual: false, now: time) { perform(token); return }
        let next = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in self?.reconcile() }
        next.tolerance = min(60, max(0, due.timeIntervalSince(time) * 0.05))
        timer = next; RunLoop.main.add(next, forMode: .common)
    }
    func stop() {
        started = false; timer?.invalidate(); timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []; state.cancel(); cancelRequest()
    }
    private func persist() { UpdateSchedulePreferences.save(state.histories, in: defaults) }
}
