import AppKit
import SwiftUI
import Security
import ApplicationServices
import IOKit.hid
import MiPadCore

/// Presentation classification only. The installer must separately validate its fixed publisher and transaction.
enum CurrentReleaseIdentity {
    static func profile() -> ReleaseProfile {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unknown }
        func matches(_ text: String) -> Bool {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { return false }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
        if matches("identifier \"org.mipad2mac.app\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"4R6JZ29FML\"") { return .developerID }
        if matches("identifier \"org.mipad2mac.app\" and certificate leaf[subject.CN] = \"MiPad2Mac Local Development\"") { return .localDevelopment }
        return .unknown
    }
    static func snapshot() -> LaunchSnapshot {
        let profile = profile()
        return LaunchSnapshot(version: appVersion, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                              profile: profile, authorizationGeneration: profile == .developerID ? 1 : 0, ruleGeneration: 1)
    }
}

enum MigrationCatalog {
    // Release owner fills the actual first release version here. Do not activate through network text or guessed versions.
    static let developerIDIntroducedIn: String? = nil
    static var rules: [MigrationRule] {
        [MigrationRule(id: "permission-identity-migration-1", introducedIn: developerIDIntroducedIn,
            sourceProfiles: [.localDevelopment], targetProfile: .developerID, targetGeneration: 1,
            cause: "此发行版本改用Apple Developer ID签名。macOS可能需要为当前应用重新确认权限。",
            capabilities: PermissionCapability.allCases, explainUnknownSource: true)]
    }
}

final class StartupCoordinator: NSObject, NSWindowDelegate {
    static let historyKey = "startupMigrationHistory.v1"
    let defaults: UserDefaults
    private(set) var history: MigrationHistory
    private(set) var current: LaunchSnapshot?
    private(set) var notices: [MigrationSelection] = []
    private(set) var initialized = false
    private var noticeWindow: NSWindow?
    /// Updater connects after validating its transaction; called before any permission/notice presentation.
    var coreInitializationCompleted: ((LaunchSnapshot) -> Void)?
    var suppressPermissionPresentation: Bool { !initialized || !notices.isEmpty }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = MigrationHistory.decode(defaults.data(forKey: Self.historyKey))
        super.init()
    }
    func initialize(current: LaunchSnapshot, trustedSource: LaunchSnapshot? = nil, rules: [MigrationRule] = MigrationCatalog.rules) {
        self.current = current
        notices = MigrationNotices.prepare(current: current, trustedSource: trustedSource, history: &history, rules: rules)
        persist(); initialized = true
        coreInitializationCompleted?(current)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.historyKey) }
    }
    func presentNotices(app: AppDelegate) {
        guard !notices.isEmpty else { return }
        if noticeWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "更新后的权限检查"; w.minSize = NSSize(width: 520, height: 440)
            w.isReleasedWhenClosed = false; w.delegate = self; w.center()
            w.contentViewController = NSHostingController(rootView: MigrationNoticeView(model: app.tabs.model, coordinator: self))
            noticeWindow = w
        }
        noticeWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func acknowledge() {
        MigrationNotices.acknowledge(notices, history: &history); persist()
        notices = []; noticeWindow?.close(); noticeWindow = nil
    }
    func later() { noticeWindow?.close() }
    // Window close/later never acknowledges a notice. Pending suppresses duplicate permission windows this session.
}

private struct MigrationNoticeView: View {
    @ObservedObject var model: SettingsPresentation
    let coordinator: StartupCoordinator
    var app: AppDelegate { model.app }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更新后的权限检查").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(coordinator.notices, id: \.rule.key) { item in
                        Text(item.unknownSource ? "如果你从旧的本地签名版本升级，macOS可能需要为当前应用重新确认权限。" : item.rule.cause)
                    }
                    Text("已授权项目无需重新操作。").foregroundStyle(.secondary)
                    permission("控制", state: app.accessibilityAllowed ? .granted : .denied) { app.requestPermissions() }
                    permission("事件发送", state: app.postAllowed ? .granted : .denied) { app.requestPermissions() }
                    permission("输入监控", state: inputState) { app.requestInputPermission() }
                    Button("重新检查") { model.act { app.refreshPermissions() } }
                    DisclosureGroup("系统设置已开启，但仍显示未授权？") {
                        Text("1. 确认正在运行的是当前安装的MiPad2Mac，正常退出其他副本。\n2. 打开系统设置 → 隐私与安全，在对应权限中移除旧条目，再添加当前应用并开启。\n3. 正常退出并重新打开MiPad2Mac，再检查权限。")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("确认说明不会更改系统权限。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("稍后") { coordinator.later() }
                Button("我已了解") { coordinator.acknowledge() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24)
    }
    var inputState: PermissionState {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeGranted { return .granted }
        if access == kIOHIDAccessTypeDenied { return .denied }
        return .unknown
    }
    func permission(_ title: String, state: PermissionState, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title); Spacer()
            Text(state == .granted ? "已授权" : (state == .denied ? "未授权" : "待确认"))
                .foregroundStyle(state == .granted ? Color.green : Color.secondary)
            Button("系统设置…", action: action).disabled(state == .granted)
        }
    }
}
