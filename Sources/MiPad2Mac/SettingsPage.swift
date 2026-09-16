import AppKit
import ServiceManagement

enum CloseBehavior: Int {
    case menuBar, dock, quit
    static var current: CloseBehavior {
        CloseBehavior(rawValue: UserDefaults.standard.integer(forKey: "windowCloseBehavior")) ?? .menuBar
    }
}

final class SettingsPage: NSObject {
    let closePicker = NSPopUpButton()
    let loginToggle = NSButton(checkboxWithTitle: "登录 Mac 时自动启动", target: nil, action: nil)
    let loginStatus = NativeLayout.text("")
    let loginError = NativeLayout.text("")
    var view: NSView!
    override init() {
        super.init()
        closePicker.addItems(withTitles: ["关闭到菜单栏（隐藏 Dock 图标）", "关闭到 Dock（保留 Dock 图标）", "关闭就退出软件"])
        closePicker.selectItem(at: CloseBehavior.current.rawValue)
        closePicker.target = self; closePicker.action = #selector(closeChanged)
        loginToggle.target = self; loginToggle.action = #selector(loginChanged)
        view = NativeLayout.page([
            NativeLayout.text("关闭窗口", heading: true), closePicker,
            NativeLayout.text("点击主窗口左上角红色关闭按钮时生效。默认关闭到菜单栏：程序继续控制笔，Dock 中不显示运行图标，可点击菜单栏 HID 重新打开。关闭到 Dock：窗口隐藏，点击 Dock 图标即可返回。选择退出：停止控制并释放笔接口。黄色最小化和绿色全屏按钮保持系统行为。"),
            NativeLayout.text("开机自启动", heading: true), loginToggle, loginStatus, loginError,
            NativeLayout.row([NSButton(title: "打开登录项设置…", target: self, action: #selector(openLoginSettings)), NSButton(title: "重新检查", target: self, action: #selector(refresh))]),
            NativeLayout.text("自启动发生在登录 macOS 后。建议先把应用放入“应用程序”文件夹，再开启此选项，避免移动或删除构建目录后失效。若显示“等待系统批准”，打开系统设置 → 通用 → 登录项与扩展，允许 MiPad2Mac；以系统显示的实际名称为准。"),
            NativeLayout.text("登录项许可与控制权限、输入监控分别管理。自启动后若缺少输入相关权限，应用会显示申请页面。系统阻止注册时会在此显示错误，不会显示为已开启。")
        ])
        refresh()
    }
    @objc func closeChanged() {
        UserDefaults.standard.set(closePicker.indexOfSelectedItem, forKey: "windowCloseBehavior")
    }
    @objc func refresh() {
        let status = SMAppService.mainApp.status
        loginToggle.state = (status == .enabled || status == .requiresApproval) ? .on : .off
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
