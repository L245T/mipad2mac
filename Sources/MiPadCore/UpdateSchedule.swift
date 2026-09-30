import Foundation

public enum UpdateInterval: Int, CaseIterable {
    case daily = 1, weekly = 7, monthly = 30
    public var seconds: TimeInterval { Double(rawValue) * 86_400 }
    public var title: String { self == .daily ? "每天" : "每\(rawValue)天" }
}
public struct UpdateCheckHistory: Codable, Equatable {
    public var lastSuccess: Date?
    public var lastFailure: Date?
    public var retryAfter: Date?
    /// Old releases recorded both failures and successes under lastUpdateCheck. Do not relabel that as success.
    public var legacyLastAttempt: Date?
    public init(lastSuccess: Date? = nil, lastFailure: Date? = nil, retryAfter: Date? = nil, legacyLastAttempt: Date? = nil) {
        self.lastSuccess = lastSuccess; self.lastFailure = lastFailure; self.retryAfter = retryAfter; self.legacyLastAttempt = legacyLastAttempt
    }
}
public struct UpdateRequestToken: Equatable {
    public let id: UUID
    public let channel: UpdateChannel
    public let generation: Int
    public let manual: Bool
}
public enum UpdateCheckOutcome: Equatable { case success, failure(retryAfter: Date?) }
public struct UpdateSchedule {
    public static let failureCooldown: TimeInterval = 6 * 3_600
    public private(set) var enabled: Bool
    public private(set) var interval: UpdateInterval
    public private(set) var channel: UpdateChannel
    public private(set) var generation = 0
    public private(set) var active: UpdateRequestToken?
    public private(set) var histories: [String: UpdateCheckHistory]
    public init(enabled: Bool, interval: UpdateInterval, channel: UpdateChannel, histories: [String: UpdateCheckHistory] = [:]) {
        self.enabled = enabled; self.interval = interval; self.channel = channel; self.histories = histories
    }
    /// Returns the old request when a configuration change invalidates it.
    @discardableResult public mutating func configure(enabled: Bool, interval: UpdateInterval, channel: UpdateChannel) -> UpdateRequestToken? {
        let invalidated = self.channel != channel || (!enabled && active?.manual == false)
        let old = invalidated ? active : nil
        if self.channel != channel { generation += 1 }
        if invalidated { active = nil }
        self.enabled = enabled; self.interval = interval; self.channel = channel
        return old
    }
    /// Keep a backward clock change from postponing checks indefinitely. Server Retry-After remains absolute.
    public mutating func normalizeClock(now: Date) {
        for key in histories.keys {
            if let date = histories[key]?.lastSuccess, date > now { histories[key]?.lastSuccess = now }
            if let date = histories[key]?.lastFailure, date > now { histories[key]?.lastFailure = now }
            if let date = histories[key]?.legacyLastAttempt, date > now { histories[key]?.legacyLastAttempt = now }
        }
    }
    public func nextDue(now: Date) -> Date? {
        guard enabled, active == nil else { return nil }
        let h = histories[channel.rawValue] ?? UpdateCheckHistory()
        var due = (h.lastSuccess ?? h.legacyLastAttempt).map { $0.addingTimeInterval(interval.seconds) } ?? now
        if let failed = h.lastFailure { due = max(due, failed.addingTimeInterval(Self.failureCooldown)) }
        if let server = h.retryAfter { due = max(due, server) }
        return due
    }
    public func serverRetryAfter(now: Date) -> Date? {
        guard let date = histories[channel.rawValue]?.retryAfter, date > now else { return nil }
        return date
    }
    public mutating func begin(manual: Bool, now: Date) -> UpdateRequestToken? {
        guard active == nil, serverRetryAfter(now: now) == nil else { return nil }
        if !manual { guard let due = nextDue(now: now), due <= now else { return nil } }
        let token = UpdateRequestToken(id: UUID(), channel: channel, generation: generation, manual: manual)
        active = token; return token
    }
    @discardableResult public mutating func complete(_ token: UpdateRequestToken, outcome: UpdateCheckOutcome, now: Date) -> Bool {
        guard active == token, token.channel == channel, token.generation == generation else { return false }
        active = nil
        var h = histories[channel.rawValue] ?? UpdateCheckHistory()
        switch outcome {
        case .success: h.lastSuccess = now; h.lastFailure = nil; h.retryAfter = nil; h.legacyLastAttempt = nil
        case .failure(let date): h.lastFailure = now; h.retryAfter = date.flatMap { $0 > now ? $0 : nil }
        }
        histories[channel.rawValue] = h; return true
    }
    public mutating func cancel() { active = nil; generation += 1 }
}
public enum UpdateSchedulePreferences {
    public static let intervalKey = "updateCheckIntervalDays"
    public static let historyKey = "updateScheduleHistory.v1"
    private struct Stored: Codable { var schema = 1; let channels: [String: UpdateCheckHistory] }
    public static func interval(in defaults: UserDefaults) -> UpdateInterval {
        UpdateInterval(rawValue: defaults.integer(forKey: intervalKey)) ?? .daily
    }
    public static func histories(in defaults: UserDefaults) -> [String: UpdateCheckHistory] {
        if let data = defaults.data(forKey: historyKey), let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.schema == 1 {
            return stored.channels
        }
        var migrated: [String: UpdateCheckHistory] = [:]
        for channel in UpdateChannel.allCases {
            let time = (defaults.object(forKey: "lastUpdateCheck." + channel.rawValue) as? Double) ??
                (channel == .stable ? defaults.object(forKey: "lastUpdateCheck") as? Double : nil)
            if let time, time.isFinite, time > 0 { migrated[channel.rawValue] = UpdateCheckHistory(legacyLastAttempt: Date(timeIntervalSince1970: time)) }
        }
        return migrated
    }
    public static func save(_ histories: [String: UpdateCheckHistory], in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(Stored(channels: histories)) { defaults.set(data, forKey: historyKey) }
    }
}
public enum HTTPRetryAfter {
    public static func date(_ value: String?, now: Date) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Double(raw), seconds.isFinite {
            let result = now.addingTimeInterval(seconds)
            return result.timeIntervalSince1970.isFinite ? result : nil
        }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = format; formatter.isLenient = false
            if let date = formatter.date(from: raw) { return max(now, date) }
        }
        return nil
    }
}
