import AppKit
import MiPadCore

final class UpdateChecker {
    static let projectURL = URL(string: "https://github.com/L245T/mipad2mac")!
    var changed: (String) -> Void = { _ in }
    /// 013 subscribes to this structured check result; download/install never writes check history.
    var completed: (UpdateRequestToken, UpdateCheckOutcome, PublishedRelease?) -> Void = { _, _, _ in }
    /// Channel changes and successful candidate replacement invalidate dependent downloads.
    var candidateChanged: (PublishedRelease?, UpdateChannel, UUID?) -> Void = { _, _, _ in }
    private(set) var candidate: PublishedRelease?
    private var task: URLSessionDataTask?
    private weak var manualWindow: NSWindow?
    private let defaults: UserDefaults
    let scheduler: UpdateScheduler
    private let session: URLSession
    init(defaults: UserDefaults = .standard, session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; scheduler = UpdateScheduler(defaults: defaults, now: now)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: configuration)
        scheduler.perform = { [weak self] token in self?.begin(token) }
        scheduler.cancelRequest = { [weak self] in self?.task?.cancel(); self?.task = nil; self?.manualWindow = nil }
    }
    var channel: UpdateChannel { scheduler.state.channel }
    var interval: UpdateInterval { scheduler.state.interval }
    var idleMessage: String {
        "更新渠道：\(channel.title)。自动检查\(scheduler.state.enabled ? "：" + interval.title : "已关闭")；可随时手动检查。"
    }
    var availableRelease: PublishedRelease? {
        candidate?.isNewer(than: appVersion, channel: channel) == true ? candidate : nil
    }
    func start() { scheduler.start() }
    func stop() { scheduler.stop(); session.invalidateAndCancel() }
    func selectChannel(_ value: UpdateChannel) {
        guard value != channel else { return }
        candidate = nil
        defaults.set(value.rawValue, forKey: "updateChannel")
        candidateChanged(nil, value, nil)
        changed("更新渠道：\(value.title)。")
        scheduler.configurationChanged()
    }
    func selectInterval(_ value: UpdateInterval) {
        defaults.set(value.rawValue, forKey: UpdateSchedulePreferences.intervalKey)
        scheduler.configurationChanged()
        if scheduler.state.active == nil { changed(idleMessage) }
    }
    func setAutomatically(_ enabled: Bool) {
        defaults.set(enabled, forKey: "checkUpdatesAutomatically")
        scheduler.configurationChanged()
        if scheduler.state.active == nil { changed(idleMessage) }
    }
    func check(manual: Bool, window: NSWindow) {
        if !manual { scheduler.reconcile(); return }
        guard scheduler.state.active == nil else { return }
        manualWindow = window
        guard scheduler.requestManual() else {
            manualWindow = nil
            let message = "更新服务要求稍后再试；请在服务冷却时间结束后重新检查。"
            changed(message); showResult(message, release: nil, window: window)
            return
        }
    }
    private func begin(_ token: UpdateRequestToken) {
        changed("正在检查\(token.channel.title)更新…")
        fetch(page: 1, releases: [], bytes: 0, token: token)
    }
    private func fetch(page: Int, releases: [PublishedRelease], bytes: Int, token: UpdateRequestToken) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/L245T/mipad2mac/releases?per_page=100&page=\(page)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MiPad2Mac/\(appVersion)", forHTTPHeaderField: "User-Agent")
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.scheduler.isCurrent(token) else { return }
                let http = response as? HTTPURLResponse
                let now = self.scheduler.now()
                var retryAfter = HTTPRetryAfter.date(http?.value(forHTTPHeaderField: "Retry-After"), now: now)
                if http?.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
                   let raw = http?.value(forHTTPHeaderField: "X-RateLimit-Reset"), let seconds = Double(raw), seconds.isFinite {
                    retryAfter = max(retryAfter ?? now, Date(timeIntervalSince1970: seconds))
                }
                func finish(_ message: String, outcome: UpdateCheckOutcome, release: PublishedRelease? = nil) {
                    self.task = nil
                    let window = self.manualWindow; self.manualWindow = nil
                    guard self.scheduler.complete(token, outcome: outcome) else { return }
                    if outcome == .success {
                        self.candidate = release
                        self.candidateChanged(release, token.channel, token.id)
                    }
                    // Subscribers may switch channels synchronously while reacting to a candidate.
                    guard self.channel == token.channel, self.scheduler.state.generation == token.generation else { return }
                    self.changed(message)
                    self.completed(token, outcome, release)
                    // Background checks only update state. They never focus windows, download or install.
                    if token.manual, let window, self.channel == token.channel,
                       self.scheduler.state.generation == token.generation {
                        let download = release?.isNewer(than: appVersion, channel: token.channel) == true || ReleaseVersion(appVersion) == nil ? release : nil
                        self.showResult(message, release: download, window: window)
                    }
                }
                if error != nil { finish("无法检查更新，请检查网络后重试。", outcome: .failure(retryAfter: retryAfter)); return }
                guard http?.statusCode == 200 else {
                    finish("更新服务暂不可用（HTTP \(http?.statusCode ?? 0)），无法判断是否有更新。", outcome: .failure(retryAfter: retryAfter)); return
                }
                guard let data, data.count <= 4_194_304, bytes + data.count <= 10_485_760,
                      let batch = try? JSONDecoder().decode([PublishedRelease].self, from: data) else {
                    finish("版本列表格式异常或超过读取上限，无法判断是否有更新。", outcome: .failure(retryAfter: retryAfter)); return
                }
                let all = releases + batch
                if http?.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true {
                    guard page < 10 else { finish("版本列表超过读取上限，无法判断是否有更新。", outcome: .failure(retryAfter: retryAfter)); return }
                    self.fetch(page: page + 1, releases: all, bytes: bytes + data.count, token: token)
                    return
                }
                guard let release = PublishedRelease.latest(in: all, channel: token.channel) else {
                    finish("未找到可比较的\(token.channel.title)版本；不能据此判断当前版本是否最新。", outcome: .success); return
                }
                guard ReleaseVersion(appVersion) != nil else {
                    finish("当前版本\(appVersion)无法自动排序。可打开发布页面查看\(release.tag_name)。", outcome: .success, release: release); return
                }
                if release.isNewer(than: appVersion, channel: token.channel) {
                    let kind = release.isPrerelease ? "预发布版" : "正式版"
                    finish("发现\(kind)\(release.tag_name)（当前\(appVersion)）。", outcome: .success, release: release)
                } else {
                    finish("当前\(appVersion)，\(token.channel.title)渠道没有发现版本号更高的更新。", outcome: .success, release: release)
                }
            }
        }
        task?.resume()
    }
    private func showResult(_ message: String, release: PublishedRelease?, window: NSWindow) {
        let alert = NSAlert(); alert.messageText = "检查更新 · \(channel.title)"; alert.informativeText = message
        alert.addButton(withTitle: "好")
        // Preserve the manual-download route until 013 supplies a trusted installation candidate.
        let url = release?.downloadURL
        if url != nil { alert.addButton(withTitle: "打开下载页面") }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn, let url { NSWorkspace.shared.open(url) }
        }
    }
}
