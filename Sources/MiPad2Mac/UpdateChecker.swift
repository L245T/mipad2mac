import AppKit
import MiPadCore

final class UpdateChecker {
    static let projectURL = URL(string: "https://github.com/L245T/mipad2mac")!
    static let releasesURL = URL(string: "https://github.com/L245T/mipad2mac/releases/latest")!
    var changed: (String) -> Void = { _ in }
    private var task: URLSessionDataTask?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()
    func check(manual: Bool, window: NSWindow) {
        guard task == nil else { return }
        if !manual {
            guard UserDefaults.standard.bool(forKey: "checkUpdatesAutomatically"),
                  Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastUpdateCheck") > 86400 else { return }
        }
        changed("正在检查更新…")
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/L245T/mipad2mac/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MiPad2Mac/\(appVersion)", forHTTPHeaderField: "User-Agent")
        task = session.dataTask(with: request) { [weak self, weak window] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }; self.task = nil
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                var message: String; var newer = false
                let status = (response as? HTTPURLResponse)?.statusCode
                if error != nil { message = "无法检查更新，请检查网络后重试。" }
                else if status == 404 { message = "仓库尚未发布可用的正式 Release；不能据此判断当前版本是否最新。" }
                else if status != 200 { message = "更新服务暂不可用（HTTP \(status ?? 0)），请稍后重试。" }
                else if let data, data.count <= 1_048_576,
                        let release = try? JSONDecoder().decode(PublishedRelease.self, from: data),
                        ReleaseVersion(release.tag_name) != nil, !release.draft, !release.prerelease {
                    newer = release.isNewer(than: appVersion)
                    message = newer ? "发现新版本 \(release.tag_name)（当前 \(appVersion)）" : "当前 \(appVersion)，没有发现更新的正式版本。"
                } else { message = "版本信息格式不符合预期，未执行更新。" }
                self.changed(message)
                // Automatic checks only update visible status; they never interrupt pen control.
                if manual, let window {
                    let alert = NSAlert(); alert.messageText = "检查更新"; alert.informativeText = message
                    alert.addButton(withTitle: "好")
                    if newer { alert.addButton(withTitle: "打开下载页面") }
                    alert.beginSheetModal(for: window) { response in
                        if newer && response == .alertSecondButtonReturn { NSWorkspace.shared.open(Self.releasesURL) }
                    }
                }
            }
        }
        task?.resume()
    }
}
