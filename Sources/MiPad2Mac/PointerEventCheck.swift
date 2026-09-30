import AppKit
import ApplicationServices
import MiPadCore

/// Explicit local diagnostic: isolated preferences, no HID access, events sent into its own window.
final class PointerEventCheck: NSObject, NSApplicationDelegate {
    private let suite = "MiPad2Mac-event-check-" + UUID().uuidString
    private var output: PointerOutput!
    private var defaults: UserDefaults!
    private var window: NSWindow!
    private let view = PointerTestView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
    private var originalCursor = CGPoint.zero
    private var blocked: String?
    private var failures: [String] = []
    private var steps: [(Double, () -> Void)] = []
    private var checks: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        originalCursor = CGEvent(source: nil)?.location ?? .zero
        defaults = UserDefaults(suiteName: suite)!
        output = PointerOutput(defaults: defaults, observeApplications: false)
        output.longPress.enabled = false
        output.tabletEnabled = true
        let id = Bundle.main.bundleIdentifier ?? "org.mipad2mac.app"
        output.navigation.set(.browse, for: id, name: "本地事件验收")
        window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MiPad2Mac 本地事件验收"; window.contentView = view
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let frame = window.convertToScreen(view.bounds)
        let top = NSScreen.screens.first!.frame.maxY
        output.mapping = Mapping(bounds: CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height))
        view.record = { print($0) }
        output.longPressDiagnostic = { print($0) }
        append {
            self.pen(); self.pen(0.5, 0.6); self.pen(0.5, 0.7); self.pen(down: false)
        }
        append {
            self.check(self.view.bridgeDown == 0 && self.view.bridgeUp == 0, "滚动没有左键点击")
            self.check(self.view.receivedScrollPhases.contains(1) && self.view.receivedScrollPhases.contains(4), "滚动开始与结束实际到达")
            self.check(self.view.receivedTabletContacts == 0, "浏览没有数位笔接触")
            self.pen(); self.pen(down: false)
        }
        append {
            self.check(self.view.receivedClickCounts == [1], "浏览短按完整单击到达")
            self.pen(); self.pen(0.5, 0.6); self.output.release()
            self.pen(0.5, 0.7); self.pen(down: false)
        }
        append {
            self.check(self.view.receivedScrollPhases.contains(8), "取消滚动实际到达")
            self.check(self.view.bridgeClicks == 1, "取消后同次接触没有点击")
            self.output.longPress.enabled = true
            self.pen()
        }
        append(after: 0.8) { self.pen(down: false) }
        append {
            self.check(self.view.receivedRightClicks == 1, "浏览静止长按右键到达")
            self.output.release()
            self.output.navigation.set(.pointer, for: id, name: "本地事件验收")
            self.output.longPress.enabled = false
            self.pen(); self.pen(0.55, 0.55); self.pen(down: false)
        }
        append {
            self.check(self.view.receivedDrags > 0 && self.view.receivedTabletContacts > 0, "指针首笔与数位笔拖动到达")
            self.finish()
        }
        runNext()
    }
    private func pen(_ x: Double = 0.5, _ y: Double = 0.5, down: Bool = true) {
        output.receive(Sample(x: x, y: y, touching: down, inRange: true,
                              pressure: 4096, tiltX: 30, tiltY: -20, positionValid: true))
    }
    private func append(after delay: Double = 0.2, _ step: @escaping () -> Void) { steps.append((delay, step)) }
    private func runNext() {
        guard !steps.isEmpty else { return }
        let next = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + next.0) {
            guard CGPreflightPostEventAccess(), AXIsProcessTrusted() else {
                self.blocked = "本地验收程序缺少已有事件发送或设备控制授权"
                self.finish(); return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                self.blocked = "本地验收窗口不在前台，停止发送测试事件"
                self.finish(); return
            }
            next.1(); self.runNext()
        }
    }
    private func check(_ condition: Bool, _ text: String) {
        if condition { checks.append(text) } else { failures.append(text) }
    }
    private func finish() {
        output.release(); CGWarpMouseCursorPosition(originalCursor)
        defaults.removePersistentDomain(forName: suite)
        let result: [String: Any] = ["passed": blocked == nil && failures.isEmpty, "blocked": blocked ?? "", "checks": checks, "failures": failures,
            "clickCounts": view.receivedClickCounts, "scrollPhases": view.receivedScrollPhases,
            "rightClicks": view.receivedRightClicks, "tabletContacts": view.receivedTabletContacts,
            "AXTrusted": AXIsProcessTrusted(), "postAccess": CGPreflightPostEventAccess(),
            "postedDown": output.downCount, "postedUp": output.upCount, "postedScroll": output.scrollEventCount,
            "warpError": output.lastWarpError.rawValue,
            "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            if let index = CommandLine.arguments.firstIndex(of: "--event-check-output"), index + 1 < CommandLine.arguments.count {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
            }
        }
        NSApp.terminate(nil)
    }
}
