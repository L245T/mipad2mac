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
            cause: "此版本改用Apple Developer ID签名。签名身份变更后，旧版本的授权记录可能无法用于当前应用。若仍显示未授权，请重新添加权限。",
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

final class StartupCoordinator {
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
    func acknowledge() {
        MigrationNotices.acknowledge(notices, history: &history); persist()
        notices = []
    }
    // Hiding or closing the main window never acknowledges a notice.
}

struct MigrationPermissionNotice: View {
    @ObservedObject var model: SettingsPresentation
    var body: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 10) {
                Label("更新后的权限说明", systemImage: "info.circle")
                    .font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                ForEach(model.app.startupCoordinator.notices, id: \.rule.key) { item in
                    Text(item.unknownSource ? "如果从旧的本地签名版本升级，旧版本的授权记录可能因签名身份变更而无法用于当前应用。若仍显示未授权，请重新添加权限。" : item.rule.cause)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(model.app.permissionsReady ? "权限已就绪，无需重新操作。" : "请先查看下方权限状态，再处理未授权或待确认的项目。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("我已了解") { model.act { model.app.startupCoordinator.acknowledge() } }
                }
            }
        }
    }
}

/// Recovery instructions live in the main permission page, separate from permission status.
private final class PermissionRecoveryState: ObservableObject { @Published var expanded = false }

struct PermissionRecoverySection: View {
    @StateObject private var state = PermissionRecoveryState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var expandForMigration = false
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
                    .accessibilityHint("显示重新添加权限的操作指引")
                if state.expanded {
                    PermissionRecoveryInstructions().transition(.opacity).padding(.top, 2)
                }
            }
        }
        .onAppear { if expandForMigration { state.expanded = true } }
        .onChange(of: expandForMigration) { value in if value { state.expanded = true } }
    }
}

struct PermissionRecoveryInstructions: View {
    var controlName: String {
        if #available(macOS 27, *) { return "设备控制和数据访问" }; return "辅助功能"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            step("1", title: "在系统设置中重新添加应用", detail: "打开系统设置 → 隐私与安全，进入“\(controlName)”或“输入监控”。只处理未授权或待确认的项目。\n选中MiPad2Mac，点“−”移除；再点“+”，选择当前安装的MiPad2Mac.app，点“打开”并开启开关。")
            Button("在访达中显示当前应用") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                .padding(.leading, 28)
            Text("请选当前安装的应用，不要选旧版或安装镜像中的副本。")
                .font(.footnote).foregroundStyle(.secondary).padding(.leading, 28)
            Divider()
            step("2", title: "返回MiPad2Mac，点“重新检查”", detail: "若系统提示需退出后重新打开，再按提示操作。")
            PermissionRecoveryDemo().padding(.leading, 28)
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
