import AppKit
import ApplicationServices
import IOKit.hid
import MiPadCore

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.1"
let appSourceRevision = Bundle.main.object(forInfoDictionaryKey: "MiPadSourceRevision") as? String ?? "本地调试"


final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let reader = HIDReader()
    let output = PointerOutput()
    var permissionPage: PermissionPage!
    var permissionDialogPage: PermissionPage!
    var permissionWindow: NSWindow?
    var tabs: NSTabView!
    var automaticControl = AutomaticControl()
    let updateChecker = UpdateChecker()
    let testRecord = TestRecord()
    let settingsPage = SettingsPage()
    let sponsorSection = SponsorSection()
    let controlSummary = NativeLayout.text("准备启用笔控制")
    let updateLabel = NativeLayout.text("可手动检查 GitHub 上发布的正式版本。")
    let autoUpdate = NativeToggle("启动时检查更新（每天最多一次）")
    let menuState = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let menuControl = NSMenuItem(title: "启用鼠标控制", action: nil, keyEquivalent: "")
    let menuTablet = NSMenuItem(title: "压力与倾斜输出", action: nil, keyEquivalent: "")
    let menuScreens = NSMenuItem(title: "目标显示器", action: nil, keyEquivalent: "")
    let rateTestLabel = NSTextField(wrappingLabelWithString: "测试会记录 15 秒实际输入；请持续用笔画圈。无需启用鼠标控制。")
    let rateTestButton = NSButton(title: "测试输入速率（15 秒）", target: nil, action: nil)
    var monitoring = UserDefaults.standard.bool(forKey: "testMonitoringEnabled")
    let monitoringToggle = NativeToggle("开启测试监控与日志")
    let recordStateButton = NSButton(title: "记录当前状态", target: nil, action: nil)
    let tabletToggle = NativeToggle("输出数位笔压力与倾斜")
    let capturePicker = NSPopUpButton()
    let captureButton = NSButton(title: "开始 30 秒笔报文采集", target: nil, action: nil)
    let captureLabel = NativeLayout.text("尚未采集；每次选择一个操作，采集前后静置作对照。")
    var captureActive = false
    var rateTestActive = false
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let statusLabel = NSTextField(wrappingLabelWithString: "尚未启动")
    let countsLabel = NSTextField(wrappingLabelWithString: "")
    let packetLabel = NSTextField(wrappingLabelWithString: "")
    let sampleLabel = NSTextField(wrappingLabelWithString: "尚未收到坐标")
    let permissionsLabel = NSTextField(wrappingLabelWithString: "")
    let controlLabel = NSTextField(wrappingLabelWithString: "控制未启用：选择屏幕尚不生效；笔的移动来自系统原生处理。")
    let screenPicker = NSPopUpButton()
    let rotationPicker = NSPopUpButton()
    let flipX = NSButton(checkboxWithTitle: "水平翻转", target: nil, action: nil)
    let flipY = NSButton(checkboxWithTitle: "垂直翻转", target: nil, action: nil)
    let enableButton = NSButton(title: "启用鼠标控制", target: nil, action: nil)
    var displays: [CGDirectDisplayID] = []
    var enabled = false
    var latestSample: Sample?
    var timer: Timer?
    var sleepObserver: NSObjectProtocol?
    var testWindow: NSWindow?
    var rateTime = ProcessInfo.processInfo.systemUptime
    var rateReports = 0
    var rateOutput = 0
    var permissionCheckedAt = -Double.infinity
    var accessibilityAllowed = false
    var postAllowed = false
    var inputAllowed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load directly from this bundle so Dock does not depend on stale Launch Services icon metadata.
        if let iconURL = Bundle.main.url(forResource: "MiPad2Mac", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        UserDefaults.standard.register(defaults: ["tabletOutputEnabled": true])
        output.tabletEnabled = UserDefaults.standard.bool(forKey: "tabletOutputEnabled")
        buildWindow()
        buildMenu()
        refreshScreens()
        reader.status = { [weak self] text in self?.statusLabel.stringValue = text; self?.testRecord.append(text) }
        reader.disconnected = { [weak self] in self?.finishPenCapture(reason: "设备断开"); self?.disable() }
        reader.sample = { [weak self] sample in
            guard let self else { return }
            self.latestSample = sample
            if self.enabled { self.output.receive(sample) }
        }
        output.didPost = { [weak self] in self?.reader.measurement?.recordPost(at: ProcessInfo.processInfo.systemUptime) }
        applyMonitoring()
        reader.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshStats() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.disable() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStats()
        updateChecker.changed = { [weak self] text in self?.updateLabel.stringValue = text }
        updateChecker.check(manual: false, window: window)

    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.delegate = self
        window.title = "MiPad2Mac \(appVersion) · 实验版"
        window.minSize = NSSize(width: 640, height: 440)
        window.setFrameAutosaveName("MiPadMainWindow")
        window.center(); window.isReleasedWhenClosed = false
        for label in [statusLabel, countsLabel, packetLabel, sampleLabel, permissionsLabel, controlLabel, rateTestLabel] { label.isSelectable = true }
        packetLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        screenPicker.target = self; screenPicker.action = #selector(mappingChanged)
        screenPicker.setAccessibilityLabel("目标显示器")
        rotationPicker.addItems(withTitles: ["0°", "90°", "180°", "270°"])
        rotationPicker.target = self; rotationPicker.action = #selector(mappingChanged)
        rotationPicker.setAccessibilityLabel("旋转方向")
        for control in [flipX, flipY] { control.target = self; control.action = #selector(mappingChanged) }
        enableButton.target = self; enableButton.action = #selector(toggle)
        enableButton.bezelStyle = .rounded
        enableButton.controlSize = .large
        controlSummary.font = .systemFont(ofSize: 15, weight: .semibold)
        rateTestButton.target = self; rateTestButton.action = #selector(startRateTest)
        tabletToggle.target = self; tabletToggle.action = #selector(tabletModeChanged)
        tabletToggle.state = output.tabletEnabled ? .on : .off
        let controlPage = NativeLayout.page([
            NativeLayout.text("平板笔控制", heading: true),
            NativeLayout.text("将平板上的笔操作映射到指定显示器。当前仅支持触控笔输入。"),
            statusLabel,
            NativeLayout.text("目标显示器（修改后暂停控制）", heading: true), screenPicker,
            NativeLayout.row([NSTextField(labelWithString: "方向"), rotationPicker, flipX, flipY]),
            NativeLayout.card([controlSummary, enableButton]),
            NativeLayout.row([NSButton(title: "重新连接", target: self, action: #selector(reconnect)), NSButton(title: "权限检查…", target: self, action: #selector(showPermissions))]),
            NativeLayout.text("压力、倾斜与虚拟按键", heading: true),
            tabletToggle,
            NativeLayout.text("默认开启并记住选择，也可通过菜单栏 HID 切换。开启后传递压感与倾斜，关闭后使用普通鼠标输出。切换会结束当前笔画；已开启的控制会继续，已暂停的控制保持暂停。已在本机 Photoshop 2026 验证，其他环境待验证。"),
            NativeLayout.text("虚拟按键：捏、双击和滑动笔杆尚未识别到可用控制数据，目前不映射功能；报文采集保留在测试页。"),
            NativeLayout.text("两种控制方式", heading: true),
            NativeLayout.text("未开启 · macOS 原生处理\nMiPad2Mac 不接管笔，系统仍可能响应笔的移动。根据本机测试，光标可能留在原来的屏幕，点击与笔尖位置不一定对应；本页的目标屏幕、旋转和翻转设置不会生效。暂停控制不等于禁用触控笔。"),
            NativeLayout.text("已开启 · MiPad2Mac 控制\n程序接管已识别的笔输入，将笔尖位置映射到所选屏幕，轻点转换为鼠标单击，按住移动转换为拖动；旋转和翻转设置生效。笔和触控板共用一个系统光标，不提供独立光标或手指触控；可通过上方开关选择数位笔输出，已在本机 Photoshop 2026 验证压感与倾斜，其他环境待验证。"),
            NativeLayout.text("关闭窗口后的行为可在“设置”中选择；默认留在菜单栏继续控制。暂停或退出后恢复系统原生处理，视频显示不受影响。")
        ])
        monitoringToggle.target = self; monitoringToggle.action = #selector(monitoringChanged)
        monitoringToggle.state = monitoring ? .on : .off
        recordStateButton.target = self; recordStateButton.action = #selector(recordTestState)
        capturePicker.addItems(withTitles: ["轻压与重压", "左右与前后倾斜", "捏笔杆", "双击笔杆", "滑动笔杆", "静置与普通落笔对照"])
        captureButton.target = self; captureButton.action = #selector(startPenCapture)
        let testPage = NativeLayout.page([
            monitoringToggle,
            NativeLayout.text("关闭后停止测试状态刷新、报文快照、速率测量和新增日志；已有日志仍可导出。正常笔控制所需的 HID 读取会继续，不受此开关影响。"),
            NativeLayout.text("触控笔测试", heading: true),
            NativeLayout.text("当前仅支持触控笔输入。先在控制页选择平板并启用控制，再打开平板测试页验证位置、轻点和拖动。"),
            NSButton(title: "在平板打开触控测试页", target: self, action: #selector(showTestWindow)),
            NativeLayout.text("控制输出", heading: true), controlLabel,
            NativeLayout.text("笔输入状态", heading: true), countsLabel, packetLabel, sampleLabel,
            rateTestButton, rateTestLabel,
            NativeLayout.text("笔报文诊断", heading: true),
            capturePicker, captureButton, captureLabel,
            NativeLayout.text("仅在测试监控开启时采集已打开的笔接口，保留解析前原始报文、时间及变化位。每次最多 30 秒、12000 条、2 MiB，超限计数。导出包含最近一次采集；新采集会替换上一段原始数据。"),
            NativeLayout.text("测试与调试记录", heading: true),
            NativeLayout.text("记录连接状态、速率测试结果及测试窗口收到的按下/抬起。最多保留 200 条，仅在内存保存；可手动记录当前状态、导出或清空。不是完整 USB 抓包，也不记录键盘输入。"),
            NativeLayout.row([recordStateButton, NSButton(title: "导出记录…", target: self, action: #selector(exportTestRecord)), NSButton(title: "清空记录", target: self, action: #selector(clearTestRecord))]),
            testRecord.view
        ])
        permissionPage = PermissionPage(owner: self)
        permissionDialogPage = PermissionPage(owner: self)
        let logo = NSImageView()
        logo.image = NSApp.applicationIconImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.widthAnchor.constraint(equalToConstant: 112).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 112).isActive = true
        autoUpdate.target = self; autoUpdate.action = #selector(updatePreferenceChanged)
        autoUpdate.state = UserDefaults.standard.bool(forKey: "checkUpdatesAutomatically") ? .on : .off
        let aboutPage = NativeLayout.page([logo,
            NativeLayout.text("MiPad2Mac \(appVersion)", heading: true),
            NativeLayout.text("代码摘要：\(appSourceRevision)"),
            NativeLayout.text("作者：力利欧 @L245T\nPowered by GPT6-Astra"),
            NativeLayout.text("小米平板 DP-in 笔输入适配 · 开源实验项目"),
            NSButton(title: "打开项目主页", target: self, action: #selector(openProject)),
            NativeLayout.text("版本更新", heading: true), updateLabel,
            NSButton(title: "检查更新…", target: self, action: #selector(checkUpdates)), autoUpdate,
            NativeLayout.text("检查会访问 GitHub Releases，仅提醒和打开下载页，不自动下载或安装。自动检查默认关闭；启用后不会弹窗打断笔操作。"),
            NativeLayout.text("当前仅支持触控笔输入。基于 macOS 27 开发，macOS 26 暂未测试。"),
            NativeLayout.text("赞助", heading: true),
            NativeLayout.text("如果 MiPad2Mac 对你有帮助，欢迎自愿赞助，支持项目持续维护。感谢支持！"),
            sponsorSection.view,
            NativeLayout.text("使用微信或支付宝扫描对应二维码。看不清时可点击“查看原图”放大。")
        ])
        tabs = NativeLayout.tabs([("控制", controlPage), ("权限检查", permissionPage.view), ("测试", testPage), ("设置", settingsPage.view), ("关于", aboutPage)])
        NativeLayout.install(tabs, in: window)
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "HID"
        statusItem.button?.setAccessibilityLabel("MiPad2Mac 控制菜单")
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        menuState.isEnabled = false; menu.addItem(menuState)
        menuControl.target = self; menuControl.action = #selector(menuToggle); menu.addItem(menuControl)
        menuTablet.target = self; menuTablet.action = #selector(menuToggleTablet); menu.addItem(menuTablet)
        menuTablet.state = output.tabletEnabled ? .on : .off
        menu.addItem(menuScreens); menu.addItem(.separator())
        for (title, action, key) in [("打开控制窗口", #selector(showWindow), ""), ("设置…", #selector(showSettings), ""), ("权限检查…", #selector(showPermissions), ""), ("关于 MiPad2Mac", #selector(showAbout), ""), ("检查更新…", #selector(checkUpdates), ""), ("退出 MiPad2Mac", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        let main = NSMenu(); let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        for (title, action, key) in [("关于 MiPad2Mac", #selector(showAbout), ""), ("检查更新…", #selector(checkUpdates), ""), ("设置…", #selector(showSettings), ","), ("权限检查…", #selector(showPermissions), ""), ("退出 MiPad2Mac", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; appMenu.addItem(item)
        }
        appItem.submenu = appMenu; NSApp.mainMenu = main
    }
    func menuWillOpen(_ menu: NSMenu) {
        menuState.title = "笔接口：\(reader.deviceCount > 0 ? "已连接" : "未连接") · \(enabled ? "控制中" : "已暂停")"
        menuControl.title = enabled ? "暂停鼠标控制" : (automaticControl.pending ? "取消自动启用" : "启用鼠标控制")
        menuControl.isEnabled = true
        menuTablet.state = output.tabletEnabled ? .on : .off
        let screens = NSMenu(); screens.autoenablesItems = false
        for (index, _) in displays.enumerated() {
            let item = NSMenuItem(title: screenPicker.itemTitle(at: index + 1), action: #selector(menuSelectScreen(_:)), keyEquivalent: "")
            item.target = self; item.tag = index + 1
            item.state = screenPicker.indexOfSelectedItem == index + 1 ? .on : .off
            item.isEnabled = true; screens.addItem(item)
        }
        menuScreens.submenu = screens; menuScreens.isEnabled = !displays.isEmpty
    }
    @objc func menuSelectScreen(_ sender: NSMenuItem) {
        guard sender.tag > 0, sender.tag < screenPicker.numberOfItems else { return }
        screenPicker.selectItem(at: sender.tag); mappingChanged()
    }
    @objc func menuToggle() {
        toggle()
        if !enabled && statusLabel.stringValue != "鼠标控制已暂停" { showWindow() }
    }
    @objc func showSettings() { tabs.selectTabViewItem(at: 3); settingsPage.refresh(); showWindow() }
    @objc func showPermissions() { refreshPermissions(); tabs.selectTabViewItem(at: 1); showWindow() }
    func showPermissionDialog() {
        if permissionWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 470), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "MiPad2Mac · 申请权限"; w.minSize = NSSize(width: 560, height: 400)
            w.isReleasedWhenClosed = false; w.center()
            NativeLayout.install(permissionDialogPage.view, in: w); permissionWindow = w
        }
        permissionWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func refreshPermissions() { permissionCheckedAt = -Double.infinity; refreshStats() }
    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "MiPad2Mac", .applicationVersion: appVersion, .credits: NSAttributedString(string: "作者：力利欧 @L245T\nPowered by GPT6-Astra\n基于 macOS 27 开发，macOS 26 暂未测试。\n小米平板 DP-in 笔输入适配\n当前仅支持触控笔输入")])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openProject() { NSWorkspace.shared.open(UpdateChecker.projectURL) }
    @objc func checkUpdates() { tabs.selectTabViewItem(at: 4); showWindow(); updateChecker.check(manual: true, window: window) }
    @objc func updatePreferenceChanged() {
        UserDefaults.standard.set(autoUpdate.state == .on, forKey: "checkUpdatesAutomatically")
    }

    func refreshScreens() {
        let oldIndex = screenPicker.indexOfSelectedItem - 1
        let previous = displays.indices.contains(oldIndex) ? displays[oldIndex] : nil
        displays.removeAll(); screenPicker.removeAllItems()
        var candidates: [Int] = []
        screenPicker.addItem(withTitle: "请选择平板显示器…")
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            displays.append(id)
            if CGDisplayIsBuiltin(id) == 0 && screen.localizedName.uppercased().contains("MI DISPLAY") { candidates.append(displays.count) }
            let bounds = CGDisplayBounds(id)
            screenPicker.addItem(withTitle: "\(screen.localizedName) · 逻辑 \(Int(bounds.width))×\(Int(bounds.height)) · ID \(id)\(CGDisplayIsBuiltin(id) != 0 ? "（内置）" : "")")
        }
        if let previous, let index = displays.firstIndex(of: previous) { screenPicker.selectItem(at: index + 1) }
        else if candidates.count == 1 { screenPicker.selectItem(at: candidates[0]) }
    }
    @objc func monitoringChanged() {
        monitoring = monitoringToggle.state == .on
        UserDefaults.standard.set(monitoring, forKey: "testMonitoringEnabled")
        applyMonitoring(); refreshStats()
    }
    func applyMonitoring() {
        testRecord.enabled = monitoring; reader.diagnosticsEnabled = monitoring
        rateTestButton.isEnabled = monitoring && !rateTestActive
        recordStateButton.isEnabled = monitoring
        captureButton.isEnabled = monitoring && !captureActive
        rateTime = ProcessInfo.processInfo.systemUptime; rateReports = reader.reports
        rateOutput = output.downCount + output.upCount + output.moveCount + output.dragCount
        if monitoring { testRecord.append("测试监控已开启") }
        else {
            reader.measurement = nil; rateTestActive = false
            finishPenCapture(reason: "监控关闭")
            controlLabel.stringValue = "测试监控已关闭"
            countsLabel.stringValue = "输入状态未刷新"
            packetLabel.stringValue = "报文快照已关闭"
            sampleLabel.stringValue = "坐标显示已暂停"
            rateTestLabel.stringValue = "开启测试监控后可运行 15 秒速率测试。"
        }
    }
    @objc func recordTestState() {
        guard monitoring else { return }
        testRecord.append("控制：\(enabled ? "已开启" : "未开启") · \(screenPicker.titleOfSelectedItem ?? "未选择屏幕")\n\(permissionsLabel.stringValue)\n\(countsLabel.stringValue)\n\(sampleLabel.stringValue)\n\(packetLabel.stringValue)")
    }
    @objc func exportTestRecord() { testRecord.save(in: window, extra: reader.penCapture?.export ?? "") }
    @objc func tabletModeChanged() { setTabletOutput(tabletToggle.state == .on) }
    @objc func menuToggleTablet() { setTabletOutput(!output.tabletEnabled) }
    func setTabletOutput(_ active: Bool) {
        // Release under the old event mode before switching; keep control/pause ownership intact.
        output.release()
        output.tabletEnabled = active
        UserDefaults.standard.set(active, forKey: "tabletOutputEnabled")
        tabletToggle.state = active ? .on : .off
        menuTablet.state = active ? .on : .off
        testRecord.append("压力与倾斜输出：\(active ? "开启" : "关闭")；已结束当前笔画，控制状态保持不变。")
    }
    @objc func startPenCapture() {
        guard monitoring, !captureActive, reader.deviceCount == 1 else { return }
        reader.penCapture = PenCapture(start: ProcessInfo.processInfo.systemUptime, label: capturePicker.titleOfSelectedItem ?? "笔测试")
        captureActive = true; captureButton.isEnabled = false
        captureLabel.stringValue = "采集中：前 5 秒静置，中间 20 秒操作，最后 5 秒静置。"
        testRecord.append("开始笔接口采集：\(capturePicker.titleOfSelectedItem ?? "")；\(Date())")
    }
    func finishPenCapture(reason: String) {
        guard captureActive, let capture = reader.penCapture else { return }
        capture.stop(); captureActive = false; captureButton.isEnabled = monitoring
        captureLabel.stringValue = "\(reason) · \(capture.summary)"
        testRecord.append(captureLabel.stringValue)
    }
    @objc func clearTestRecord() { testRecord.clear() }
    @objc func startRateTest() {
        guard monitoring else { return }
        guard reader.deviceCount > 0 else { rateTestLabel.stringValue = "未连接笔接口，请先连接平板。"; return }
        reader.measurement = InputRateMeasurement(start: ProcessInfo.processInfo.systemUptime)
        testRecord.append("开始 15 秒笔输入速率测试")
        rateTestActive = true; rateTestButton.isEnabled = false
        rateTestLabel.stringValue = "测试开始：请连续画圈 15 秒。启用控制时也会统计提交事件；暂停或离笔时间会计入平均值。"
    }
    func updateRateTest() {
        guard rateTestActive, let m = reader.measurement else { return }
        let remaining = m.start + m.duration - ProcessInfo.processInfo.systemUptime
        if remaining > 0 {
            rateTestLabel.stringValue = "剩余 \(Int(ceil(remaining))) 秒 · 已接收 \(m.reports) 条 · 已提交 \(m.posted) 次；请持续画圈。"
            return
        }
        rateTestActive = false; rateTestButton.isEnabled = true
        rateTestLabel.stringValue = String(format: "15 秒结果：接收 %.1f 条/秒 · 有效坐标 %.1f 条/秒 · 提交 %.1f 次/秒\n坐标变化 %d 次 · 重置 %d 条 · 相邻回调最长间隔 %.1f 毫秒\n应用层统计，含停顿；提交不代表目标应用收到，无数据时不能判断硬件速率。", m.reportRate, m.positionRate, m.postRate, m.positionChanges, m.resetReports, m.maxGap * 1000)
        testRecord.append(rateTestLabel.stringValue)
    }
    func refreshStats() {
        if captureActive, let capture = reader.penCapture {
            let remaining = capture.start + capture.duration - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { finishPenCapture(reason: "采集完成") }
            else { captureLabel.stringValue = "剩余 \(Int(ceil(remaining))) 秒 · \(capture.summary)" }
        }
        if monitoring { updateRateTest() }
        if ProcessInfo.processInfo.systemUptime - permissionCheckedAt >= 2 {
            accessibilityAllowed = AXIsProcessTrusted()
            postAllowed = CGPreflightPostEventAccess()
            inputAllowed = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            settingsPage.refresh()
            permissionCheckedAt = ProcessInfo.processInfo.systemUptime
        }
        let controlName: String
        if #available(macOS 27, *) { controlName = "设备控制和数据访问" } else { controlName = "辅助功能" }
        permissionsLabel.stringValue = "\(controlName)：\(accessibilityAllowed ? "已授权" : "未授权") · 鼠标事件发送：\(postAllowed ? "已允许" : "未允许") · 输入监控：\(inputAllowed ? "已授权" : "未授权")"
        permissionPage.update(control: accessibilityAllowed, input: inputAllowed, post: postAllowed)
        permissionDialogPage.update(control: accessibilityAllowed, input: inputAllowed, post: postAllowed)
        if monitoring {
        countsLabel.stringValue = "已打开接口：\(reader.deviceCount) · 收到报文：\(reader.reports) · 解析成功：\(reader.decoded)"
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0.001, now - rateTime)
        let totalOutput = output.downCount + output.upCount + output.moveCount + output.dragCount
        countsLabel.stringValue += String(format: "\n实时速率（只读）：接收 %.0f 报文/秒 · 提交 %.0f 事件/秒 · 重置报文 %d", Double(reader.reports - rateReports) / elapsed, Double(totalOutput - rateOutput) / elapsed, reader.resetReports)
        rateTime = now; rateReports = reader.reports; rateOutput = totalOutput
        controlLabel.stringValue = enabled
            ? "控制已启用 · 已提交按下/抬起：\(output.downCount)/\(output.upCount) · 移动/拖动：\(output.moveCount)/\(output.dragCount)\n定位调用：\(output.lastWarpError == .success ? "成功（待测试页验收）" : "失败")"
            : "控制未启用：选择屏幕尚不生效；笔的移动来自系统原生处理。"
        controlLabel.textColor = enabled ? .systemGreen : .systemOrange
        if enabled, let cursor = CGEvent(source: nil)?.location {
            controlLabel.stringValue += String(format: "\n目标点 %.0f, %.0f · 当前光标 %.0f, %.0f", output.lastPoint.x, output.lastPoint.y, cursor.x, cursor.y)
        }
        packetLabel.stringValue = reader.lastReport
        if let sample = latestSample {
            sampleLabel.stringValue = String(format: "X %.3f · Y %.3f · 接触 %@ · 范围内 %@ · 压感 %d",
                sample.x, sample.y, sample.touching ? "是" : "否", sample.inRange ? "是" : "否", sample.pressure)
            sampleLabel.stringValue += "\n倾斜 X \(sample.tiltX)° / Y \(sample.tiltY)° · barrel \(sample.barrel) · eraser \(sample.eraser) · 有效位置 \(sample.positionValid)\n实验数位笔输出 \(output.tabletEnabled ? "开" : "关") · 接近/离开提交 \(output.proximityCount)"
        }
        }
        if enabled && !permissionsReady { disable(); statusLabel.stringValue = "权限发生变化，控制已暂停。" }
        attemptAutoStart()
        controlSummary.textColor = enabled ? .systemGreen : (automaticControl.pending ? .systemOrange : .secondaryLabelColor)
        statusLabel.textColor = reader.readyForControl ? .secondaryLabelColor : .systemOrange
        controlSummary.stringValue = enabled ? "笔控制已开启" : (automaticControl.pending ? "等待设备或权限，准备自动启用" : "笔控制已暂停 · 系统原生处理")
        if !enabled {
            enableButton.title = automaticControl.pending ? "取消自动启用" : "启用鼠标控制"
            if monitoring && automaticControl.pending { controlLabel.stringValue = permissionsReady ? "等待平板屏幕和受支持的笔接口，准备自动启用。" : "请完成权限申请，授权后自动启用。" }
        }
    }
    var permissionsReady: Bool { accessibilityAllowed && postAllowed && inputAllowed }
    func attemptAutoStart() {
        guard !enabled else { return }
        if permissionsReady { permissionWindow?.close() }
        let index = screenPicker.indexOfSelectedItem - 1
        switch automaticControl.next(permissions: permissionsReady, target: displays.indices.contains(index), pen: reader.readyForControl) {
        case .wait: break
        case .requestPermissions: showPermissionDialog()
        case .enable: enableControl()
        }
    }

    @objc func requestPermissions() {
        guard !(AXIsProcessTrusted() && CGPreflightPostEventAccess()) else { return }
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        openPermissionSettings(anchor: "Privacy_Accessibility")
        permissionCheckedAt = -Double.infinity
        statusLabel.stringValue = "请在隐私与安全 → 设备控制和数据访问（旧系统为辅助功能）授权当前应用。更新后若开关已开但仍未授权，请移除旧条目再添加当前应用。"
    }
    @objc func requestInputPermission() {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted else { return }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        openPermissionSettings(anchor: "Privacy_ListenEvent")
        permissionCheckedAt = -Double.infinity
        statusLabel.stringValue = "请在隐私与安全 → 输入监控中授权当前 MiPad2Mac；随后退出并重新打开。"
    }
    private func openPermissionSettings(anchor: String) {
        // Request APIs need not display a dialog again after a previous decision.
        // Only missing permissions have an enabled request button.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        if !NSWorkspace.shared.open(url) {
            let alert = NSAlert()
            alert.messageText = "无法打开系统设置"
            alert.informativeText = "请手动打开系统设置 → 隐私与安全，选择设备控制和数据访问或输入监控。"
            alert.runModal()
        }
    }

    @objc func showTestWindow() {
        let index = screenPicker.indexOfSelectedItem - 1
        guard displays.indices.contains(index), let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displays[index]
        }) else { statusLabel.stringValue = "请先选择平板显示器。"; return }
        testWindow?.close()
        let frame = screen.visibleFrame.insetBy(dx: 60, dy: 60)
        let test = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        test.title = "MiPad2Mac · 轻点与坐标测试"
        test.isReleasedWhenClosed = false
        test.acceptsMouseMovedEvents = true
        let canvas = PointerTestView(frame: NSRect(origin: .zero, size: frame.size))
        canvas.record = { [weak self] message in self?.testRecord.append(message) }
        test.contentView = canvas
        testRecord.append("打开平板触控笔测试页；该窗口记录实际收到的事件。")
        testWindow = test
        test.makeKeyAndOrderFront(nil)
        test.makeFirstResponder(test.contentView)
        statusLabel.stringValue = "测试页已在目标屏幕打开。完整轻点计数增加才代表单击到达；橙色点应跟随笔尖。"
    }
    @objc func toggle() {
        if enabled || automaticControl.pending { pause(); return }
        automaticControl.request()
        refreshPermissions()
    }
    func enableControl() {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { automaticControl.request(); return }
        let index = screenPicker.indexOfSelectedItem - 1
        guard displays.indices.contains(index), reader.readyForControl else {
            statusLabel.stringValue = "请先选择平板屏幕，并连接支持的笔接口。"
            return
        }
        let id = displays[index]
        guard CGDisplayIsActive(id) != 0 else { displayChanged(); return }
        guard reader.setExclusive(true) else { return }
        output.mapping = Mapping(bounds: CGDisplayBounds(id), rotation: rotationPicker.indexOfSelectedItem * 90,
                                 flipX: flipX.state == .on, flipY: flipY.state == .on)
        enabled = true
        enableButton.title = "暂停鼠标控制"
        statusItem.button?.title = "HID"
        statusLabel.stringValue = "控制已启用，已独占笔接口以避免系统重复处理；暂停即恢复。"
    }
    func disable() {
        output.release(); enabled = false
        reader.setExclusive(false)
        enableButton.title = "启用鼠标控制"
        statusItem?.button?.title = "HID"
    }
    @objc func pause() { automaticControl.pause(); disable(); statusLabel.stringValue = "鼠标控制已暂停" }
    @objc func mappingChanged() { pause() }
    @objc func displayChanged() { disable(); refreshScreens() }
    @objc func reconnect() {
        finishPenCapture(reason: "重新连接"); disable(); reader.stop(); reader.resetDiagnostics()
        rateTime = ProcessInfo.processInfo.systemUptime; rateReports = 0
        rateOutput = output.downCount + output.upCount + output.moveCount + output.dragCount
        latestSample = nil; sampleLabel.stringValue = "尚未收到坐标"
        automaticControl.request()
        reader.start()
    }
    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        switch CloseBehavior.current {
        case .quit: NSApp.terminate(nil)
        case .menuBar:
            for w in NSApp.windows { w.orderOut(nil) }
            NSApp.setActivationPolicy(.accessory)
        case .dock:
            window.orderOut(nil)
            NSApp.setActivationPolicy(.regular)
        }
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { disable(); reader.stop(); timer?.invalidate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

if CommandLine.arguments.contains("--probe") {
    // Read-only probe: never requests Accessibility and never posts mouse events.
    print("MiPad2Mac \(appVersion) read-only probe")
    print("Input monitoring status: \(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)")
    for screen in NSScreen.screens { print("Display: \(screen.localizedName), \(screen.frame)") }
    let reader = HIDReader()
    reader.start()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 15))
    print("Devices: \(reader.deviceCount); reports: \(reader.reports); decoded: \(reader.decoded)")
    print(reader.lastReport)
    reader.stop()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
