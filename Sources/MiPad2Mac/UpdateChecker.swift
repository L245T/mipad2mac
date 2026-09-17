import AppKit
import MiPadCore

final class UpdateChecker {
    static let projectURL = URL(string: "https://github.com/L245T/mipad2mac")!
    var changed: (String) -> Void = { _ in }
    private var task: URLSessionDataTask?
    private var requestID = UUID()
    var channel: UpdateChannel {
        UpdateChannel(rawValue: UserDefaults.standard.string(forKey: "updateChannel") ?? "") ?? .stable
    }
    var idleMessage: String { "更新渠道：\(channel.title)。可手动检查 GitHub Release。" }
    func selectChannel(_ value: UpdateChannel) {
        guard value != channel else { return }
        requestID = UUID() // A cancelled callback must not overwrite the new channel's state.
        task?.cancel(); task = nil
        UserDefaults.standard.set(value.rawValue, forKey: "updateChannel")
        changed(idleMessage)
    }
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()
    func check(manual: Bool, window: NSWindow) {
        guard task == nil else { return }
        let selected = channel
        let checkKey = "lastUpdateCheck." + selected.rawValue
        let saved = UserDefaults.standard.object(forKey: checkKey) as? Double
        let last = saved ?? (selected == .stable ? UserDefaults.standard.double(forKey: "lastUpdateCheck") : 0)
        if !manual {
            guard UserDefaults.standard.bool(forKey: "checkUpdatesAutomatically"),
                  Date().timeIntervalSince1970 - last > 86400 else { return }
        }
        let id = UUID(); requestID = id
        changed("正在检查\(selected.title)更新…")
        fetch(page: 1, releases: [], bytes: 0, channel: selected, id: id, manual: manual, window: window)
    }
    private func fetch(page: Int, releases: [PublishedRelease], bytes: Int, channel: UpdateChannel,
                       id: UUID, manual: Bool, window: NSWindow?) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/L245T/mipad2mac/releases?per_page=100&page=\(page)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MiPad2Mac/\(appVersion)", forHTTPHeaderField: "User-Agent")
        task = session.dataTask(with: request) { [weak self, weak window] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.requestID == id else { return }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode
                func finish(_ message: String, release: PublishedRelease? = nil) {
                    self.task = nil
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck." + channel.rawValue)
                    self.changed(message)
                    // Automatic checks never interrupt pen control or install software.
                    if manual, let window {
                        let alert = NSAlert(); alert.messageText = "检查更新 · \(channel.title)"; alert.informativeText = message
                        alert.addButton(withTitle: "好")
                        let url = release?.downloadURL
                        if url != nil { alert.addButton(withTitle: "打开下载页面") }
                        alert.beginSheetModal(for: window) { response in
                            if response == .alertSecondButtonReturn, let url { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                if error != nil { finish("无法检查更新，请检查网络后重试。"); return }
                guard status == 200 else {
                    finish("更新服务暂不可用（HTTP \(status ?? 0)），无法判断是否有更新。"); return
                }
                guard let data, data.count <= 4_194_304, bytes + data.count <= 10_485_760,
                      let batch = try? JSONDecoder().decode([PublishedRelease].self, from: data) else {
                    finish("版本列表格式异常或超过读取上限，无法判断是否有更新。"); return
                }
                let all = releases + batch
                if http?.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true {
                    guard page < 10 else { finish("版本列表超过读取上限，无法判断是否有更新。"); return }
                    self.fetch(page: page + 1, releases: all, bytes: bytes + data.count,
                               channel: channel, id: id, manual: manual, window: window)
                    return
                }
                guard let release = PublishedRelease.latest(in: all, channel: channel) else {
                    finish("未找到可比较的\(channel.title)版本；不能据此判断当前版本是否最新。"); return
                }
                guard ReleaseVersion(appVersion) != nil else {
                    finish("当前版本 \(appVersion) 无法自动排序。可打开发布页面查看 \(release.tag_name)。", release: release); return
                }
                if release.isNewer(than: appVersion, channel: channel) {
                    let kind = release.isPrerelease ? "预发布版" : "正式版"
                    finish("发现\(kind) \(release.tag_name)（当前 \(appVersion)）。", release: release)
                } else {
                    finish("当前 \(appVersion)，\(channel.title)渠道没有发现版本号更高的更新。")
                }
            }
        }
        task?.resume()
    }
}
