import AppKit
import CoreServices
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

enum SystemStartupSource {
    static func detect(_ event: NSAppleEventDescriptor?) -> StartupSource {
        // Apple's open-application event stores login launch information in keyAEPropData.
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication,
              event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem else { return .user }
        return .loginItem
    }
}

final class StartupCoordinator: NSObject, NSWindowDelegate {
    static let historyKey = "startupMigrationHistory.v1"
    let defaults: UserDefaults
    private(set) var history: MigrationHistory
    private(set) var current: LaunchSnapshot?
    private(set) var notices: [MigrationSelection] = []
    private(set) var initialized = false
    private(set) var source: StartupSource = .user
    private(set) var presentation = StartupPresentation.decide(source: .user, silentLogin: true, hasMigrationNotice: false)
    private var validatedRestart: UpdateRestartContext?
    private var userOpenedWindow = false
    private var noticeWindow: NSWindow?
    /// Updater connects after validating its transaction; called before any permission/notice presentation.
    var coreInitializationCompleted: ((LaunchSnapshot) -> Void)?
    var suppressPermissionPresentation: Bool {
        !initialized || !notices.isEmpty || (!userOpenedWindow && presentation.suppressAutomaticPermissionWindow)
    }
    /// 013 must validate nonce/path/version/publisher before supplying this context and connecting its receipt callback.
    func acceptValidatedUpdateRestart(_ context: UpdateRestartContext) {
        guard !initialized, context.source.valid else { return }
        validatedRestart = context
    }
    func userDidOpenWindow() { userOpenedWindow = true }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = MigrationHistory.decode(defaults.data(forKey: Self.historyKey))
        super.init()
    }
    func initialize(current: LaunchSnapshot, systemSource: StartupSource = .user, rules: [MigrationRule] = MigrationCatalog.rules) {
        self.current = current
        source = validatedRestart.map(StartupSource.updater) ?? systemSource
        notices = MigrationNotices.prepare(current: current, trustedSource: validatedRestart?.source, history: &history, rules: rules)
        presentation = StartupPresentation.decide(source: source, silentLogin: StartupPreferences.silentLogin(in: defaults), hasMigrationNotice: !notices.isEmpty)
        persist(); initialized = true
        coreInitializationCompleted?(current)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.historyKey) }
    }
    func presentNotices(app: AppDelegate) {
        guard !notices.isEmpty else { return }
        if noticeWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 580),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "更新后的权限检查"; w.titleVisibility = .hidden
            w.minSize = NSSize(width: 560, height: 540)
            w.isReleasedWhenClosed = false; w.delegate = self; w.center()
            w.contentViewController = NSHostingController(rootView: MigrationNoticeView(model: app.tabs.model, coordinator: self))
            noticeWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        noticeWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func acknowledge() {
        MigrationNotices.acknowledge(notices, history: &history); persist()
        notices = []; noticeWindow?.close(); noticeWindow = nil
    }
    func later() { noticeWindow?.close() }
    func windowWillClose(_ notification: Notification) {
        if !presentation.showMainWindow && !userOpenedWindow { NSApp.setActivationPolicy(.accessory) }
    }
    // Window close/later never acknowledges a notice. Pending suppresses duplicate permission windows this session.
}

private final class MigrationNoticeState: ObservableObject { @Published var section = 0 }

private struct MigrationNoticeView: View {
    @StateObject private var state = MigrationNoticeState()
    @ObservedObject var model: SettingsPresentation
    let coordinator: StartupCoordinator
    var app: AppDelegate { model.app }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("更新后的权限检查").font(.title2.bold())
                if state.section == 0 {
                ForEach(coordinator.notices, id: \.rule.key) { item in
                    Text(item.unknownSource ? "如果从旧的本地签名版本升级，macOS可能需要重新确认权限。" : item.rule.cause)
                        .font(.callout).foregroundStyle(.secondary)
                }
                }
                Picker("权限帮助", selection: $state.section) {
                    Text("权限检查").tag(0); Text("重新添加权限").tag(1)
                }.pickerStyle(.segmented).labelsHidden().padding(.top, 8)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if state.section == 0 {
                    SettingsSection {
                        LabeledContent("控制与事件发送") {
                            stateText(app.accessibilityAllowed && app.postAllowed ? .granted : .denied)
                            Button("系统设置…") { model.act { app.requestPermissions() } }
                                .disabled(app.accessibilityAllowed && app.postAllowed)
                        }
                        if app.accessibilityAllowed != app.postAllowed {
                            Text("控制：\(app.accessibilityAllowed ? "已授权" : "未授权") · 事件发送：\(app.postAllowed ? "已授权" : "未授权")")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        LabeledContent("输入监控") {
                            stateText(inputState)
                            Button("系统设置…") { model.act { app.requestInputPermission() } }.disabled(inputState == .granted)
                        }
                        HStack {
                            Text(app.permissionsReady ? "权限已就绪，无需重新操作。" : "只需处理未授权或待确认的项目。")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button("重新检查") { model.act { app.refreshPermissions() } }
                        }
                    } header: { Text("当前权限") } footer: { EmptyView() }
                    SettingsSection {
                        Button { state.section = 1 } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("系统设置已开启，仍显示未授权？").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                                    Text("查看重新添加当前应用的三步指引").font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.callout).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    } else {
                        SettingsSection { PermissionRecoveryInstructions() }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack {
                Text("确认说明不会更改系统权限。").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("稍后") { coordinator.later() }
                Button("我已了解") { coordinator.acknowledge() }.keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.controlSize(.regular).labeledContentStyle(SettingsValueStyle())
    }
    var inputState: PermissionState {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeGranted { return .granted }
        if access == kIOHIDAccessTypeDenied { return .denied }
        return .unknown
    }
    func stateText(_ state: PermissionState) -> some View {
        Text(state == .granted ? "已授权" : (state == .denied ? "未授权" : "待确认"))
            .foregroundStyle(state == .granted ? Color.green : Color.secondary)
    }
}

/// Shared by the permission page and migration window; keeps recovery separate from permission status.
private final class PermissionRecoveryState: ObservableObject { @Published var expanded = false }

struct PermissionRecoverySection: View {
    @StateObject private var state = PermissionRecoveryState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { state.expanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(state.expanded ? 90 : 0)).frame(width: 12).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("系统设置已开启，仍显示未授权？").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                            Text("重新添加当前应用的权限").font(.callout).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(state.expanded ? "已展开" : "已收起")
                    .accessibilityHint("显示重新添加权限的三步指引")
                if state.expanded {
                    PermissionRecoveryInstructions().transition(.opacity).padding(.top, 2)
                }
            }
        }
    }
}

struct PermissionRecoveryInstructions: View {
    var controlName: String {
        if #available(macOS 27, *) { return "设备控制和数据访问" }; return "辅助功能"
    }
    var body: some View {
                    VStack(alignment: .leading, spacing: 14) {
                        step("1", title: "退出MiPad2Mac", detail: "从菜单栏HID选择退出MiPad2Mac，不要只关闭窗口。其他旧副本也需正常退出。")
                        Divider()
                        step("2", title: "移除旧条目，添加当前应用", detail: "系统设置 → 隐私与安全 → \(controlName)或输入监控。只处理检查未通过的项目。\n选中MiPad2Mac，点“−”移除；再点“+”，添加当前安装的MiPad2Mac.app并开启权限。")
                        Button("在访达中显示当前应用") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                            .padding(.leading, 28)
                        Text("请勿选择旧版或安装镜像中的副本。").font(.footnote).foregroundStyle(.secondary).padding(.leading, 28)
                        Divider()
                        step("3", title: "重开应用，重新检查", detail: "打开刚添加的MiPad2Mac，回到权限页点重新检查。若系统要求退出后重新打开，请按提示操作。")
                    }
    }
    func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                Text(.init(detail)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
