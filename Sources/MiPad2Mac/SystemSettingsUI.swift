import AppKit
import SwiftUI
import MiPadCore

/// The presentation bridge refreshes at the existing 2 Hz UI cadence, never the HID cadence.
final class SettingsPresentation: ObservableObject {
    unowned let app: AppDelegate
    @Published var generation = 0
    @Published var selection = 0
    private var signature = ""
    init(_ app: AppDelegate) { self.app = app }
    func sync() {
        let fields = [app.statusLabel.stringValue, app.controlSummary.stringValue,
            app.permissionsLabel.stringValue, app.updateLabel.stringValue,
            app.settingsPage.loginStatus.stringValue, app.settingsPage.loginError.stringValue,
            app.captureLabel.stringValue, app.rateTestLabel.stringValue,
            app.screenPicker.itemTitles.joined(), String(app.screenPicker.indexOfSelectedItem),
            String(app.enabled), String(app.output.tabletEnabled), String(app.monitoring),
            String(app.rotationPicker.indexOfSelectedItem), String(app.flipX.state.rawValue), String(app.flipY.state.rawValue),
            String(app.automaticControl.requested), String(app.captureActive), String(app.rateTestActive), String(app.automaticControl.pending),
            String(app.settingsPage.materialToggle.state.rawValue), String(app.settingsPage.loginToggle.state.rawValue)]
            + (app.monitoring ? [app.countsLabel.stringValue, app.sampleLabel.stringValue, app.packetLabel.stringValue, app.controlLabel.stringValue, app.testRecord.displayText] : [])
        let next = fields.joined(separator: "\u{1f}")
        if next != signature { signature = next; generation += 1 }
    }
    func act(_ action: () -> Void) { action(); app.refreshStats(); generation += 1 }
}

final class SystemSettingsController: NSSplitViewController {
    let model: SettingsPresentation
    private var opaqueSidebar: NSView?
    static let names = ["控制", "权限检查", "测试", "设置", "关于"]
    init(app: AppDelegate) { model = SettingsPresentation(app); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        let sidebarController = SettingsNavigation(model: model)
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.canCollapse = false; sidebar.minimumThickness = 220; sidebar.maximumThickness = 220
        let detail = NSSplitViewItem(viewController: SettingsContentController(model: model))
        detail.minimumThickness = 480
        addSplitViewItem(sidebar); addSplitViewItem(detail)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMaterial), name: Notification.Name("MiPadSidebarAppearanceChanged"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateMaterial), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateMaterial()
    }
    func install(in window: NSWindow) {
        window.contentViewController = self
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "MiPadSettingsToolbar")
        toolbar.showsBaselineSeparator = true
        window.toolbar = toolbar
        (splitViewItems.last?.viewController as? SettingsContentController)?.install(in: window)
        (splitViewItems.first?.viewController as? SettingsNavigation)?.install(in: window)
        selectTabViewItem(at: 0)
    }
    func selectTabViewItem(at index: Int) {
        guard Self.names.indices.contains(index) else { return }
        model.selection = index
        (splitViewItems.first?.viewController as? SettingsNavigation)?.select(index)
        model.app.window.title = Self.names[index]
        (splitViewItems.last?.viewController as? SettingsContentController)?.heading.stringValue = Self.names[index]
    }
    @objc private func updateMaterial() {
        guard let sidebar = splitViewItems.first?.viewController.view else { return }
        let enabled = UserDefaults.standard.object(forKey: "sidebarTransparency") as? Bool ?? true
        if !enabled || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            if opaqueSidebar == nil {
                let background = OpaqueSidebarBackground()
                background.frame = sidebar.bounds; background.autoresizingMask = [.width, .height]
                sidebar.addSubview(background, positioned: .below, relativeTo: nil); opaqueSidebar = background
            }
        } else { opaqueSidebar?.removeFromSuperview(); opaqueSidebar = nil }
    }
    deinit { NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }
}

struct SettingsDetail: View {
    @ObservedObject var model: SettingsPresentation
    var permissionsOnly = false
    private var app: AppDelegate { model.app }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
            if permissionsOnly { permissions }
            else {
                switch model.selection {
                case 0: control
                case 1: permissions
                case 2: testing
                case 3: settings
                default: about
                }
            }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.automatic)
            .background(Color(nsColor: .textBackgroundColor)).textSelection(.enabled)
            .controlSize(.regular).toggleStyle(SettingsToggleStyle()).labeledContentStyle(SettingsValueStyle())
    }
    private func footerNote(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func help(_ text: String) -> some View { ExplanationButton(text: text) }
    private func status(_ text: String, good: Bool) -> some View {
        Text(text).foregroundStyle(good ? Color.green : Color.secondary).font(.callout)
    }
    private var control: some View {
        Group {
            SettingsSection {
                SettingsPicker("处理方式", selection: Binding(get: { app.automaticControl.requested ? 1 : 0 }, set: { value in model.act { app.controlMode.selectedSegment = value; app.controlModeChanged() } })) {
                    Text("macOS 原生处理").tag(0); Text("MiPad2Mac 控制").tag(1)
                }
                HStack(spacing: 12) {
                    Text("状态"); Spacer(minLength: 12)
                    Text(app.controlSummary.stringValue).foregroundStyle(Color(nsColor: app.controlSummary.textColor ?? .secondaryLabelColor))
                    ExplanationButton(text: app.controlStatusHelp, label: "处理方式说明")
                }
                if !app.enabled && app.automaticControl.requested {
                    Text(app.statusLabel.stringValue).font(.callout).foregroundStyle(.secondary)
                }
                HStack { Spacer(); Button("权限检查…") { app.showPermissions() }; Button("重新连接") { model.act { app.reconnect() } } }
            } footer: {
                Text("当前仅支持触控笔输入。")
            }
            SettingsSection {
                SettingsPicker("目标显示器", selection: Binding(get: { app.screenPicker.indexOfSelectedItem }, set: { value in model.act { app.screenPicker.selectItem(at: value); app.mappingChanged() } })) {
                    ForEach(Array(app.screenPicker.itemTitles.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
                }
                SettingsPicker("旋转方向", selection: Binding(get: { app.rotationPicker.indexOfSelectedItem }, set: { value in model.act { app.rotationPicker.selectItem(at: value); app.mappingChanged() } })) {
                    ForEach(0..<4, id: \.self) { Text("\($0 * 90)°").tag($0) }
                }
                Toggle("水平翻转", isOn: Binding(get: { app.flipX.state == .on }, set: { value in model.act { app.flipX.state = value ? .on : .off; app.mappingChanged() } }))
                Toggle("垂直翻转", isOn: Binding(get: { app.flipY.state == .on }, set: { value in model.act { app.flipY.state = value ? .on : .off; app.mappingChanged() } }))
            } header: { Text("显示器") } footer: { footerNote("修改映射会结束当前笔画，处理方式保持不变。显示的是逻辑分辨率。") }
            SettingsSection("笔输入") {
                Toggle(isOn: Binding(get: { app.output.tabletEnabled }, set: { value in model.act { app.setTabletOutput(value) } })) {
                    Text("压力与倾斜"); Text("向支持的绘画软件发送笔压与倾斜数据。")
                }.accessibilityLabel("压力与倾斜")
                LabeledContent("虚拟按键") { Text("暂不支持").foregroundStyle(.secondary); help("捏、双击和滑动笔杆未在已知笔接口观察到可用控制数据，目前不映射功能。") }
            }
        }
    }
    private var permissions: some View {
        Group {
            SettingsSection {
                LabeledContent("控制与事件发送") {
                    status(app.accessibilityAllowed && app.postAllowed ? "已授权" : "未授权", good: app.accessibilityAllowed && app.postAllowed)
                    Button("申请权限…") { model.act { app.requestPermissions() } }.disabled(app.accessibilityAllowed && app.postAllowed)
                }
                LabeledContent("输入监控") {
                    status(app.inputAllowed ? "已授权" : "未授权", good: app.inputAllowed)
                    Button("申请权限…") { model.act { app.requestInputPermission() } }.disabled(app.inputAllowed)
                }
            } header: { Text("所需权限") } footer: { footerNote("选择 MiPad2Mac 控制后，权限、笔设备和目标屏幕就绪时尝试启用。输入监控授权后可能需要重启应用。") }
            SettingsSection { HStack { Text("权限检查"); help("macOS 27 的控制权限名为“设备控制和数据访问”，旧系统称“辅助功能”。两种权限分别申请，已授权按钮不可重复申请。"); Spacer(); Button("重新检查") { model.act { app.refreshPermissions() } } } }
        }
    }
    private var testing: some View {
        Group {
            SettingsSection {
                Toggle(isOn: Binding(get: { app.monitoring }, set: { value in model.act { app.monitoringToggle.state = value ? .on : .off; app.monitoringChanged() } })) {
                    Text("测试监控与日志"); Text("关闭不影响正常笔控制，已有记录仍可导出。")
                }.accessibilityLabel("测试监控与日志")
                LabeledContent("定位、轻点与拖动") { Button("打开测试页") { app.showTestWindow() } }
            }
            SettingsSection("输入与输出") {
                if app.monitoring {
                    Text(app.countsLabel.stringValue)
                    Text(app.controlLabel.stringValue)
                    Text(app.sampleLabel.stringValue)
                    DisclosureGroup("原始报文") { Text(app.packetLabel.stringValue).font(.system(.caption, design: .monospaced)) }
                } else { Text("监控已暂停").foregroundStyle(.secondary) }
                LabeledContent("输入速率") { Button("测试 15 秒") { model.act { app.startRateTest() } }.disabled(!app.monitoring || app.rateTestActive) }
                if app.monitoring { Text(app.rateTestLabel.stringValue).font(.callout).foregroundStyle(.secondary) }
            }
            SettingsSection {
                SettingsPicker("采集操作", selection: Binding(get: { app.capturePicker.indexOfSelectedItem }, set: { app.capturePicker.selectItem(at: $0); model.generation += 1 })) {
                    ForEach(Array(app.capturePicker.itemTitles.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
                }
                LabeledContent("笔报文诊断") { help("仅采集已打开的笔接口。每次最多 30 秒、12000 条、2 MiB；新采集替换旧原始数据，导出包含最近一次采集。请在操作前后静置对照。"); Button("采集 30 秒") { model.act { app.startPenCapture() } }.disabled(!app.monitoring || app.captureActive) }
                Text(app.captureLabel.stringValue).font(.callout).foregroundStyle(.secondary)
            }
            SettingsSection("测试记录") {
                HStack { Button("记录状态") { model.act { app.recordTestState() } }.disabled(!app.monitoring); Spacer(); Button("导出…") { app.exportTestRecord() }; Button("清空") { model.act { app.clearTestRecord() } } }
                Text(app.testRecord.displayText.isEmpty ? "暂无记录" : app.testRecord.displayText)
                    .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var settings: some View {
        Group {
            SettingsSection {
                Toggle(isOn: Binding(get: { app.settingsPage.materialToggle.state == .on }, set: { value in model.act { app.settingsPage.materialToggle.state = value ? .on : .off; app.settingsPage.materialChanged() } })) {
                    Text("透明侧栏"); Text("采用系统材质，遵循降低透明度设置。")
                }.accessibilityLabel("透明侧栏")
                SettingsPicker("关闭窗口时", selection: Binding(get: { app.settingsPage.closePicker.indexOfSelectedItem }, set: { value in model.act { app.settingsPage.closePicker.selectItem(at: value); app.settingsPage.closeChanged() } })) {
                    Text("留在菜单栏").tag(0); Text("保留 Dock 图标").tag(1); Text("退出软件").tag(2)
                }
            } header: { Text("外观与窗口") } footer: { footerNote("留在菜单栏时隐藏 Dock 图标，笔控制继续运行。") }
            SettingsSection {
                Toggle("登录 Mac 时自动启动", isOn: Binding(get: { app.settingsPage.loginToggle.state == .on }, set: { value in model.act { app.settingsPage.loginToggle.state = value ? .on : .off; app.settingsPage.loginChanged() } }))
                if !app.settingsPage.loginStatus.isHidden { Text(app.settingsPage.loginStatus.stringValue).foregroundStyle(.orange) }
                if !app.settingsPage.loginError.stringValue.isEmpty { Text(app.settingsPage.loginError.stringValue).foregroundStyle(.red) }
                LabeledContent("登录项管理") { Button("系统设置…") { app.settingsPage.openLoginSettings() }; Button("重新检查") { model.act { app.settingsPage.refresh() } } }
            } header: { Text("启动") } footer: { footerNote("如需系统批准，请在“通用 → 登录项与扩展”允许 MiPad2Mac。") }
        }
    }
    private var about: some View {
        Group {
            SettingsSection {
                HStack(spacing: 20) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 88, height: 88)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("MiPad2Mac \(appVersion)").font(.title2.bold())
                        Text("代码摘要：\(appSourceRevision)").font(.caption).foregroundStyle(.secondary)
                        Text("作者：力利欧 @L245T\nPowered by GPT6-Astra")
                    }
                }.padding(.vertical, 8)
                LabeledContent("开源项目") { Button("打开 GitHub") { app.openProject() } }
            } footer: { footerNote("小米平板 DP-in 笔输入适配工具。基于 macOS 27 开发，macOS 26 暂未测试。") }
            SettingsSection {
                SettingsPicker("更新渠道", selection: Binding(get: { app.updateChecker.channel }, set: { value in model.act { app.updateChecker.selectChannel(value) } })) {
                    ForEach(UpdateChannel.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }
                LabeledContent("软件更新") { Button("检查更新…") { app.checkUpdates() } }
                Toggle("启动时检查更新", isOn: Binding(get: { app.autoUpdate.state == .on }, set: { value in model.act { app.autoUpdate.state = value ? .on : .off; app.updatePreferenceChanged() } }))
                Text(app.updateLabel.stringValue).font(.callout).foregroundStyle(.secondary)
            } header: { Text("版本更新") } footer: { footerNote("稳定版仅检查正式发布；Beta 版也检查预发布。各渠道每天最多自动检查一次，不自动下载或安装。") }
            SettingsSection("赞助") {
                Text("如果这个工具对你有帮助，欢迎自愿赞助。")
                HStack(alignment: .top, spacing: 24) { sponsor("微信", file: "wechat", ext: "png"); sponsor("支付宝", file: "alipay", ext: "jpg") }.frame(maxWidth: .infinity)
            }
        }
    }
    private func sponsor(_ title: String, file: String, ext: String) -> some View {
        VStack {
            Text(title)
            if let url = Bundle.main.url(forResource: file, withExtension: ext, subdirectory: "Sponsor"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 180, maxHeight: 240)
                Button("查看原图") { NSWorkspace.shared.open(url) }
            }
        }.frame(maxWidth: .infinity)
    }
}

private final class ExplanationState: ObservableObject { @Published var shown = false }
private struct ExplanationButton: View {
    let text: String
    var label: String = "查看说明"
    @StateObject private var state = ExplanationState()
    var body: some View {
        Button { state.shown.toggle() } label: { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) }
            .buttonStyle(.plain).accessibilityLabel(label)
            .popover(isPresented: $state.shown) { Text(text).font(.callout).multilineTextAlignment(.leading).padding(16).frame(width: 320).fixedSize(horizontal: false, vertical: true) }
    }
}
