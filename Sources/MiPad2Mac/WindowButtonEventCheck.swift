import AppKit
import ApplicationServices
import MiPadCore

/// Explicit isolated native-window receiver. No HID, user preferences or user window actions.
final class WindowButtonEventCheck: NSObject, NSApplicationDelegate {
    private let suite = "MiPad2Mac-window-button-check-" + UUID().uuidString
    private var defaults: UserDefaults!
    private var output: PointerOutput!
    private var window: WindowButtonCheckWindow!
    private var overlay: NSWindow?
    private var steps: [(Double, () -> Void)] = []
    private var checks: [String] = []
    private var failures: [String] = []
    private var logs: [String] = []
    private var point = CGPoint.zero
    private var original = NSRect.zero
    private var originalCursor = CGPoint.zero
    private var externalReceiver: Process?
    private var top: CGFloat { NSScreen.screens.first!.frame.maxY }
    private var id: String { Bundle.main.bundleIdentifier! }
    private func check(_ value: Bool, _ label: String) {
        checks.append(label); if !value { failures.append(label) }; print("\(value ? "PASS" : "FAIL") \(label)")
    }
    private func append(_ delay: Double = 0.15, _ action: @escaping () -> Void) { steps.append((delay, action)) }
    private func runNext() {
        guard !steps.isEmpty else { finish(); return }
        let next = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + next.0) { next.1(); self.runNext() }
    }
    private func setup(_ mode: PenApplicationMode = .browse, own: Bool = true, fullScreen: Bool = false) {
        output?.release(); overlay?.orderOut(nil); overlay = nil; window?.orderOut(nil)
        output = PointerOutput(defaults: defaults, observeApplications: false, diagnosticOwnWindow: own)
        output.longPress.enabled = true; output.longPress.compatibilityEnabled = false
        output.tabletEnabled = true; output.momentumEnabled = false
        output.buttonPreferences.radius = 6
        output.applicationProfiles.defaultApplicationMode = mode
        output.navigation.set(mode == .browse ? .browse : .pointer, for: id, name: "原生窗口验收")
        output.applicationProfiles.set(mode, for: id, name: "原生窗口验收")
        output.longPressDiagnostic = { [weak self] in self?.logs.append($0); print($0) }
        window = WindowButtonCheckWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = fullScreen ? [.fullScreenPrimary] : [.fullScreenNone]
        let screen = NSScreen.screens.first!.visibleFrame
        window.setFrameOrigin(NSPoint(x: screen.midX - 210, y: screen.midY - 115))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        original = window.frame
    }
    private func bounds(_ type: NSWindow.ButtonType) -> CGRect {
        let button = window.standardWindowButton(type)!
        let r = window.convertToScreen(button.convert(button.bounds, to: nil))
        return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }
    private func miss(_ type: NSWindow.ButtonType) -> CGPoint {
        let r = bounds(type); return CGPoint(x: r.midX, y: r.minY - 2)
    }
    private func pen(_ p: CGPoint, down: Bool) {
        let r = window.frame
        output.mapping = Mapping(bounds: CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height))
        let m = output.mapping.bounds
        // Never send diagnostic events into another application or the desktop.
        let number = NSWindow.windowNumber(at: NSPoint(x: p.x, y: top - p.y), belowWindowWithWindowNumber: 0)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), m.contains(p),
              number == window.windowNumber else {
            failures.append("原生fixture失去前台或坐标超出窗口"); return
        }
        output.receive(Sample(x: (p.x - m.minX) / (m.width - 1), y: (p.y - m.minY) / (m.height - 1),
                              touching: down, inRange: true, pressure: down ? 4000 : 0))
    }
    private func tap(_ p: CGPoint) { point = p; pen(p, down: true); pen(p, down: false) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        originalCursor = CGEvent(source: nil)?.location ?? .zero
        defaults = UserDefaults(suiteName: suite)!
        for mode in [PenApplicationMode.browse, .pointer, .drawing] {
            append { self.setup(mode) }
            append(0.6) { self.tap(self.miss(.closeButton)) }
            append { self.check(!self.window.isVisible && self.window.downs == 1 && self.window.ups == 1,
                "\(mode.title)原生红按钮近点按实际关闭且成对事件到达") }
        }
        append { self.setup(.browse, own: false) }
        append(0.6) { self.tap(self.miss(.closeButton)) }
        append { self.check(!self.window.isVisible, "生产自身窗口保护下原生红按钮仍可容错") }
        append { self.setup(); self.output.buttonPreferences.radius = 0 }
        append(0.6) { self.tap(self.miss(.closeButton)) }
        append { self.check(self.window.isVisible, "范围0保留标题栏原始点按") }
        append { self.setup(); self.window.standardWindowButton(.closeButton)?.isEnabled = false }
        append(0.6) { self.tap(self.miss(.closeButton)) }
        append { self.check(self.window.isVisible, "禁用原生红按钮不被触发") }
        append { self.setup(); self.window.standardWindowButton(.closeButton)?.isHidden = true }
        append(0.6) { self.tap(self.miss(.closeButton)) }
        append { self.check(self.window.isVisible, "隐藏原生红按钮经真实命中核对回退") }
        append { self.setup() }
        append(0.6) {
            let a = self.bounds(.closeButton), b = self.bounds(.miniaturizeButton)
            self.tap(CGPoint(x: (a.maxX + b.minX) / 2, y: a.midY))
        }
        append { self.check(self.window.isVisible && !self.window.isMiniaturized, "红黄等距不任意选择按钮") }
        append { self.setup() }
        append(0.6) { self.tap(self.miss(.miniaturizeButton)) }
        append(0.9) { self.check(self.window.isMiniaturized, "原生黄按钮近点按实际最小化"); self.window.deminiaturize(nil) }
        append { self.setup() }
        append(0.6) { self.tap(self.miss(.zoomButton)) }
        append(0.6) { self.check(self.window.frame != self.original, "非全屏原生绿按钮近点按实际缩放") }
        append { self.setup(fullScreen: true) }
        append(0.6) { self.tap(self.miss(.zoomButton)) }
        append(2) {
            self.check(self.window.styleMask.contains(.fullScreen), "全屏绿按钮别名去重后近点按实际进入全屏")
            if self.window.styleMask.contains(.fullScreen) { self.window.toggleFullScreen(nil) }
        }
        append(2) { self.setup() }
        append(0.6) { self.point = self.miss(.closeButton); self.pen(self.point, down: true)
            self.window.standardWindowButton(.closeButton)?.isEnabled = false }
        append { self.pen(self.point, down: false) }
        append { self.check(self.window.isVisible, "落笔后按钮禁用保留原始点击") }
        append { self.setup() }
        append(0.6) {
            self.point = self.miss(.closeButton); self.pen(self.point, down: true)
            self.window.setFrameOrigin(NSPoint(x: self.original.minX + 12, y: self.original.minY))
        }
        append { self.pen(self.point, down: false) }
        append { self.check(self.window.isVisible && self.window.downs == 0, "落笔后窗口移动取消待提交点击") }
        append { self.setup() }
        append(0.6) {
            self.point = self.miss(.closeButton); self.pen(self.point, down: true)
            let button = self.bounds(.closeButton)
            self.overlay = NSWindow(contentRect: NSRect(x: button.minX, y: self.top - button.maxY,
                width: button.width, height: button.height), styleMask: [.borderless], backing: .buffered, defer: false)
            self.overlay?.backgroundColor = .gray; self.overlay?.level = .floating; self.overlay?.orderFront(nil)
        }
        append { self.pen(self.point, down: false) }
        append { self.check(self.window.isVisible, "按钮被其他窗口遮挡不辅助点击"); self.overlay?.orderOut(nil) }
        append { self.setup() }
        append(0.6) {
            self.point = self.miss(.closeButton); self.pen(self.point, down: true)
            self.output.release(); self.pen(self.point, down: false)
        }
        append { self.check(self.window.isVisible && self.window.downs == 0, "释放控制取消红按钮候选") }
        append { self.setup() }
        append(0.6) { self.point = self.miss(.closeButton); self.pen(self.point, down: true) }
        append(NSEvent.doubleClickInterval + 0.1) { self.pen(self.point, down: false) }
        append { self.check(self.window.isVisible && self.window.rights == 0, "原生顶栏长接触保留原始点不触发红按钮或右键") }
        append { self.setup() }
        append(0.6) { self.point = self.miss(.closeButton); self.pen(self.point, down: true) }
        append { self.pen(CGPoint(x: self.point.x + 25, y: self.point.y), down: true) }
        append { self.pen(CGPoint(x: self.point.x + 25, y: self.point.y), down: false) }
        append { self.check(self.window.isVisible && self.window.drags > 0,
            "红按钮附近拖动保留原始顶栏拖动而非关闭") }
        if let index = CommandLine.arguments.firstIndex(of: "--external-window-fixture"),
           index + 2 < CommandLine.arguments.count {
            let executable = CommandLine.arguments[index + 1], resultPath = CommandLine.arguments[index + 2]
            append {
                self.output.release(); self.window.orderOut(nil)
                let receiver = Process(); receiver.executableURL = URL(fileURLWithPath: executable)
                receiver.arguments = [resultPath]
                do { try receiver.run(); self.externalReceiver = receiver }
                catch { self.failures.append("无法启动跨PID原生fixture") }
            }
            append(0.9) { self.tapExternalClose() }
            append(0.5) {
                let data = try? Data(contentsOf: URL(fileURLWithPath: resultPath))
                let result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                self.check(result?["closed"] as? Bool == true && result?["down"] as? Int == 1
                    && result?["up"] as? Int == 1 && self.externalReceiver?.isRunning == false,
                    "非Adobe绘画例外的跨PID原生红按钮实际关闭，独立进程收到成对标记事件")
            }
        }
        runNext()
    }
    private func tapExternalClose() {
        guard let receiver = externalReceiver, receiver.isRunning,
              let app = NSRunningApplication(processIdentifier: receiver.processIdentifier),
              let bundleID = app.bundleIdentifier, bundleID != id,
              app.processIdentifier != getpid() else { failures.append("跨PID窗口身份不可用"); return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.03)
        func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(e, 0.03)
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, key as CFString, &result) == .success ? result : nil
        }
        func rect(_ e: AXUIElement) -> CGRect? {
            guard let p = value(e, kAXPositionAttribute), let s = value(e, kAXSizeAttribute),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }
        guard let windows = value(axApp, kAXWindowsAttribute) as? [AXUIElement], windows.count == 1,
              let w = windows.first, let frame = rect(w),
              let b = value(w, kAXCloseButtonAttribute), CFGetTypeID(b) == AXUIElementGetTypeID(),
              let button = rect(unsafeBitCast(b, to: AXUIElement.self)) else {
            failures.append("跨PID窗口按钮元数据不可用"); return
        }
        let point = CGPoint(x: button.midX, y: button.minY - 2)
        let number = NSWindow.windowNumber(at: NSPoint(x: point.x, y: top - point.y), belowWindowWithWindowNumber: 0)
        guard frame.contains(point), number > 0,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              (windows.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == receiver.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == receiver.processIdentifier else {
            failures.append("跨PIDfixture不在原始点最上层或前台"); return
        }
        output = PointerOutput(defaults: defaults, observeApplications: false)
        output.tabletEnabled = true; output.longPress.enabled = true
        output.setApplicationProfileMode(.drawing, for: bundleID, name: "独立非Adobe绘画fixture")
        output.buttonPreferences.radius = 6
        output.longPressDiagnostic = { [weak self] in self?.logs.append($0); print($0) }
        output.mapping = Mapping(bounds: frame)
        let x = (point.x - frame.minX) / (frame.width - 1), y = (point.y - frame.minY) / (frame.height - 1)
        output.receive(Sample(x: x, y: y, touching: true, inRange: true, pressure: 4000))
        output.receive(Sample(x: x, y: y, touching: false, inRange: true))
    }
    private func finish() {
        output.release(); overlay?.orderOut(nil); window?.orderOut(nil)
        if externalReceiver?.isRunning == true { externalReceiver?.terminate() }
        CGWarpMouseCursorPosition(originalCursor)
        defaults.removePersistentDomain(forName: suite)
        let result: [String: Any] = ["passed": failures.isEmpty, "checks": checks, "failures": failures, "logs": logs,
                                    "AXTrusted": AXIsProcessTrusted(), "postAccess": CGPreflightPostEventAccess()]
        if let i = CommandLine.arguments.firstIndex(of: "--event-check-output"), i + 1 < CommandLine.arguments.count,
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), options: .atomic)
        }
        print("原生窗口按钮验收：\(checks.count)项，失败\(failures.count)项")
        NSApp.terminate(nil)
    }
}
private final class WindowButtonCheckWindow: NSWindow {
    var downs = 0, ups = 0, rights = 0, drags = 0
    override func sendEvent(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == bridgeEventTag {
            switch event.type {
            case .leftMouseDown: downs += 1
            case .leftMouseUp: ups += 1
            case .rightMouseDown: rights += 1
            case .leftMouseDragged: drags += 1
            default: break
            }
        }
        super.sendEvent(event)
    }
}

/// A disposable manual receiver for a real pen. Deliberately starts no input bridge or HID reader.
final class ManualWindowButtonFixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "MiPad2Mac 窗口按钮测试"
        window.collectionBehavior = [.fullScreenPrimary]
        let note = NSTextField(wrappingLabelWithString: "这是可以关闭的临时测试窗口，不连接设备，也不接管触控笔。\n\n请由已开启控制的MiPad2Mac发送笔输入，点按红、黄、绿按钮附近。关闭只退出本测试窗口；最小化后可从Dock恢复。")
        note.frame = NSRect(x: 30, y: 55, width: 460, height: 145)
        window.contentView?.addSubview(note)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
