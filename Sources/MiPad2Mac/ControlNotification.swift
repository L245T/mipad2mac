import AppKit
import UserNotifications

/// Permission is requested only after the first successful automatic takeover.
final class ControlNotification: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var generation = UUID()
    override init() { super.init(); center.delegate = self }
    func cancel() { generation = UUID(); center.removePendingNotificationRequests(withIdentifiers: ["tablet-control"]) }
    func show(isStillActive: @escaping () -> Bool) {
        let token = UUID(); generation = token
        center.requestAuthorization(options: [.alert]) { [weak self] allowed, _ in
            DispatchQueue.main.async {
                guard let self, allowed, self.generation == token, isStillActive() else { return }
                let content = UNMutableNotificationContent()
                content.title = "平板触控笔已由 MiPad2Mac 控制"
                content.body = "已自动选择平板屏幕。现在可用触控笔定位、点击和拖动。"
                self.center.add(UNNotificationRequest(identifier: "tablet-control", content: content, trigger: nil))
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
