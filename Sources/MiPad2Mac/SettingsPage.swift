import AppKit
import ServiceManagement

enum CloseBehavior: Int {
    case menuBar, dock, quit
    static var current: CloseBehavior {
        CloseBehavior(rawValue: UserDefaults.standard.integer(forKey: "windowCloseBehavior")) ?? .menuBar
    }
}

final class SettingsPage: NSObject {
    let materialToggle = NativeToggle("侧栏透明磨砂")
    let closePicker = NSPopUpButton()
    let loginToggle = NativeToggle("登录 Mac 时自动启动")
    let loginStatus = NativeLayout.text("")
    let loginError = NativeLayout.text("")
    var view: NSView!
    override init() {
        super.init()
        materialToggle.state = UserDefaults.standard.object(forKey: "sidebarTransparency") as? Bool == false ? .off : .on
        materialToggle.target = self; materialToggle.action = #selector(materialChanged)
        closePicker.addItems(withTitles: ["留在菜单栏", "保留 Dock 图标", "退出软件"])
        closePicker.selectItem(at: CloseBehavior.current.rawValue)
        closePicker.target = self; closePicker.action = #selector(closeChanged)
        loginToggle.target = self; loginToggle.action = #selector(loginChanged)
        view = NativeLayout.page([
            NativeLayout.text("外观与窗口", heading: true),
            NativeLayout.card([
                materialToggle,
                NativeLayout.note("使用系统原生侧栏材质，并遵循降低透明度设置。"),
                NativeLayout.separator(),
                SettingsRow("关闭窗口时", control: closePicker, help: "留在菜单栏：继续运行，隐藏 Dock 图标，从菜单栏 HID 重开。保留 Dock 图标：只隐藏窗口。退出软件：停止控制并释放笔接口。黄色与绿色窗口按钮保持系统行为。")
            ]),
            NativeLayout.text("启动", heading: true),
            NativeLayout.card([
                loginToggle, loginStatus, loginError, NativeLayout.separator(),
                SettingsRow("登录项管理", control: NativeLayout.row([NSButton(title: "系统设置…", target: self, action: #selector(openLoginSettings)), NSButton(title: "重新检查", target: self, action: #selector(refresh))]), help: "自启动发生在登录 macOS 后。建议将应用放入应用程序文件夹。若等待批准，请在系统设置 → 通用 → 登录项与扩展允许 MiPad2Mac。登录项许可与输入权限分别管理。")
            ])
        ])
        refresh()
    }
    @objc func materialChanged() {
        UserDefaults.standard.set(materialToggle.state == .on, forKey: "sidebarTransparency")
        NotificationCenter.default.post(name: Notification.Name("MiPadSidebarAppearanceChanged"), object: nil)
    }
    @objc func closeChanged() {
        UserDefaults.standard.set(closePicker.indexOfSelectedItem, forKey: "windowCloseBehavior")
    }
    @objc func refresh() {
        let status = SMAppService.mainApp.status
        loginToggle.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        loginToggle.statusText = status == .requiresApproval ? "待批准" : nil
        loginError.isHidden = loginError.stringValue.isEmpty
        loginStatus.isHidden = status == .enabled || status == .notRegistered
        loginError.textColor = .systemRed
        loginStatus.textColor = status == .enabled ? .systemGreen : (status == .notRegistered ? .secondaryLabelColor : .systemOrange)
        switch status {
        case .enabled: loginStatus.stringValue = "自启动：已开启"
        case .requiresApproval: loginStatus.stringValue = "自启动：等待系统批准，请打开登录项设置允许 MiPad2Mac。"
        case .notRegistered: loginStatus.stringValue = "自启动：未开启"
        case .notFound: loginStatus.stringValue = "自启动：系统未找到应用，请将应用放入“应用程序”后重试。"
        @unknown default: loginStatus.stringValue = "自启动：系统状态未知，请查看登录项设置。"
        }
    }
    @objc func loginChanged() {
        loginError.stringValue = ""
        do {
            if loginToggle.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { loginError.stringValue = "操作未完成：\(error.localizedDescription)" }
        refresh()
    }
    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
