import AppKit
import ApplicationServices
import MiPadCore

/// Explicit local diagnostic: isolated preferences, no HID access, events sent into its own window.
final class PointerEventCheck: NSObject, NSApplicationDelegate {
    private let suite = "MiPad2Mac-event-check-" + UUID().uuidString
    private var output: PointerOutput!
    private var defaults: UserDefaults!
    private var window: EventCheckWindow!
    private let view = PointerTestView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
    private let textView = EventCheckTextView(frame: NSRect(x: 40, y: 30, width: 640, height: 80))
    private var originalFrame = NSRect.zero
    private var originalMapping = Mapping(bounds: .zero)
    private var scrollCountBeforeTitleDrag = 0
    private var drawingDownBefore = 0
    private var textTraceBefore = 0
    private var textScrollBefore = 0
    private let leftScroll = EventCheckScrollRegion(frame: NSRect(x: 30, y: 170, width: 280, height: 210))
    private let rightScroll = EventCheckScrollRegion(frame: NSRect(x: 410, y: 170, width: 280, height: 210))
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
        window = EventCheckWindow(contentRect: view.bounds, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MiPad2Mac 本地事件验收"; window.contentView = view
        view.setAccessibilityElement(true); view.setAccessibilityRole(.scrollArea)
        textView.string = "alpha beta gamma\nsecond paragraph\n"
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.isEditable = false; textView.isSelectable = true
        view.addSubview(textView)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let frame = window.convertToScreen(view.bounds)
        let top = NSScreen.screens.first!.frame.maxY
        output.mapping = Mapping(bounds: CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height))
        view.record = { print($0) }
        output.longPressDiagnostic = { print($0) }
        append { self.pen() }
        append(after: 0.04) { self.pen(0.5, 0.6) }
        append(after: 0.04) { self.pen(0.5, 0.7) }
        append(after: 0.08) {
            let expected = self.output.mapping.point(x: 0.5, y: 0.7)
            let cursor = CGEvent(source: nil)?.location ?? .zero
            self.check(hypot(cursor.x - expected.x, cursor.y - expected.y) < 2, "滚动过程中系统光标跟随笔尖")
            self.pen(0, 0, down: false)
        }
        append {
            let expected = self.output.mapping.point(x: 0.5, y: 0.7)
            let cursor = CGEvent(source: nil)?.location ?? .zero
            self.check(hypot(cursor.x - expected.x, cursor.y - expected.y) < 2, "滚动抬笔不跳回落笔锚点")
            self.check(self.view.bridgeDown == 0 && self.view.bridgeUp == 0, "滚动没有左键点击")
            self.check(self.view.receivedScrollPhases.contains(1) && self.view.receivedScrollPhases.contains(4), "滚动开始与结束实际到达")
            self.check(self.view.receivedTabletContacts == 0, "浏览没有数位笔接触")
            self.pen(); self.pen(down: false)
        }
        append {
            self.check(self.view.receivedClickCounts == [1], "浏览短按完整单击到达")
        }
        // Start an independent scroll; a nearby tap within the click interval now means selection.
        append(after: NSEvent.doubleClickInterval + 0.05) {
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
            self.output.release(); self.pen(); self.pen(down: false)
        }
        let cadence = max(0.01, min(0.1, NSEvent.doubleClickInterval / 4))
        append(after: cadence) { self.pen(); self.pen(down: false) }
        append(after: cadence) { self.pen(); self.pen(down: false) }
        append(after: cadence) {
            self.check(Array(self.view.receivedClickCounts.suffix(3)) == [1, 2, 3], "连续单／双／三击计数实际到达")
            self.output.release(); self.pen(); self.pen(down: false)
        }
        append(after: cadence) { self.pen(); self.pen(0.55); self.pen(down: false) }
        append(after: cadence) { self.pen(); self.pen(down: false) }
        append(after: cadence) {
            self.check(self.view.receivedDragClickCounts.last == 2, "双击后拖选保留双击语义")
            self.check(self.view.receivedClickCounts.last == 1, "拖动后下一次点击从单击开始")
            self.output.release(); self.output.tabletEnabled = false
            self.textPen(character: 2); self.textPen(character: 2, down: false)
        }
        append(after: cadence) { self.textPen(character: 2); self.textPen(character: 2, down: false) }
        append(after: cadence) {
            let selection = self.textView.selectedRange()
            self.check((self.textView.string as NSString).substring(with: selection) == "alpha", "AppKit文字框双击选词")
            self.textPen(character: 2); self.textPen(character: 2, down: false)
        }
        append(after: cadence) {
            self.check(self.textView.selectedRange().length >= "alpha beta gamma".count, "AppKit文字框三击选择段落")
            self.output.release()
            self.textPen(character: 0)
        }
        append(after: cadence) { self.textPen(character: 10) }
        append(after: cadence) { self.textPen(character: 10, down: false) }
        append(after: cadence) {
            self.check(self.textView.selectedRange().length > 1, "指针模式保留文字拖选")
            self.output.release()
            self.output.applicationProfiles.set(.drawing, for: id, name: "本地事件验收")
            self.output.longPress.enabled = true; self.output.tabletEnabled = true
            self.drawingDownBefore = self.view.bridgeDown
            self.pen()
        }
        append(after: 0.8) { self.pen(0.55, 0.5); self.pen(down: false) }
        append {
            self.check(self.view.bridgeDown == self.drawingDownBefore + 1, "绘画模式在全局长按开启时仍即时落笔")
            self.check(self.view.receivedRightClicks == 1, "绘画模式停笔不触发右键")
            self.output.release()
            self.output.applicationProfiles.set(.browse, for: id, name: "本地事件验收")
            self.output.longPress.enabled = true
            self.output.tabletEnabled = true
            self.originalMapping = self.output.mapping
            let screen = NSScreen.screens.first!.frame
            self.output.mapping = Mapping(bounds: CGRect(x: screen.minX, y: 0, width: screen.width, height: screen.height))
            self.originalFrame = self.window.frame
            self.scrollCountBeforeTitleDrag = self.output.scrollEventCount
            self.titlePen()
        }
        append { self.titlePen(offset: 10) }
        append { self.titlePen(offset: 50) }
        append { self.titlePen(offset: 50, down: false) }
        append {
            self.check(abs(self.window.frame.minX - self.originalFrame.minX) > 20, "浏览模式实际拖动窗口顶栏")
            self.check(self.output.scrollEventCount == self.scrollCountBeforeTitleDrag, "顶栏拖动没有滚动事件")
            self.window.setFrame(self.originalFrame, display: true)
            self.output.mapping = self.originalMapping
            self.output.release(); self.output.longPress.enabled = false
            self.view.addSubview(self.leftScroll); self.view.addSubview(self.rightScroll)
            self.pen(0.15, 0.3)
        }
        append { self.pen(0.15, 0.4) }
        append { self.pen(0.8, 0.45) }
        append { self.pen(0, 0, down: false) }
        append {
            self.check(self.leftScroll.scrolls > 0 && self.rightScroll.scrolls == 0, "光标跨越相邻内容区仍只滚动原落笔区域")
            let expected = self.output.mapping.point(x: 0.8, y: 0.45)
            let cursor = CGEvent(source: nil)?.location ?? .zero
            self.check(hypot(cursor.x - expected.x, cursor.y - expected.y) < 2, "跨区滚动光标跟随且抬笔不跳变")
            self.output.release()
            self.textTraceBefore = self.textView.trace.count
            self.textPen(character: 2)
        }
        append(after: 0.04) { self.textPen(character: 2, verticalOffset: 20) }
        append(after: 0.04) { self.textPen(character: 2, down: false, verticalOffset: 20) }
        append {
            self.check(self.textView.bridgeScrolls > 0, "浏览模式在只读文字区域实际收到滚动")
            self.check(self.textView.trace.count == self.textTraceBefore, "只读文字滑动没有左键选字事件")
            self.output.release(); self.textView.isEditable = true
            self.textTraceBefore = self.textView.trace.count
            self.textScrollBefore = self.textView.bridgeScrolls
            self.textPen(character: 2)
        }
        append(after: 0.04) { self.textPen(character: 10) }
        append(after: 0.04) { self.textPen(character: 10, down: false) }
        append {
            self.check(self.textView.trace.count > self.textTraceBefore && self.textView.selectedRange().length > 1, "浏览模式保留可编辑输入框拖选")
            self.check(self.textView.bridgeScrolls == self.textScrollBefore, "可编辑输入框拖选不发送滚动")
            self.output.release(); self.textView.isEditable = false
            self.output.longPress.enabled = true
            self.textTraceBefore = self.textView.trace.count
            self.textScrollBefore = self.textView.bridgeScrolls
            self.textPen(character: 2); self.textPen(character: 2, down: false)
        }
        append(after: cadence) { self.textPen(character: 2) }
        append(after: cadence) { self.textPen(character: 10) }
        append(after: cadence) { self.textPen(character: 10, down: false) }
        append(after: cadence) {
            let trace = Array(self.textView.trace.dropFirst(self.textTraceBefore))
            self.check(trace.contains { $0.hasPrefix("down count=2") } && self.textView.selectedRange().length > "alpha".count, "浏览模式双击按住拖动扩展选词")
            self.check(self.textView.bridgeScrolls == self.textScrollBefore, "浏览双击拖选不发送滚动")
            self.output.release(); self.textTraceBefore = self.textView.trace.count
            self.textPen(character: 2); self.textPen(character: 2, down: false)
        }
        append(after: cadence) { self.textPen(character: 2); self.textPen(character: 2, down: false) }
        append(after: cadence) { self.textPen(character: 2) }
        append(after: cadence) { self.textPen(character: 22) }
        append(after: cadence) { self.textPen(character: 22, down: false) }
        append(after: cadence) {
            let trace = Array(self.textView.trace.dropFirst(self.textTraceBefore))
            self.check(trace.contains { $0.hasPrefix("down count=3") } && self.textView.selectedRange().length > "alpha beta gamma\n".count, "浏览模式三击按住拖动扩展段落选择")
            self.check(self.textView.bridgeScrolls == self.textScrollBefore && self.view.receivedRightClicks == 1, "浏览三击拖选不发送滚动或长按右键")
            self.textTraceBefore = self.textView.trace.count
            self.textPen(character: 2)
        }
        append(after: cadence) { self.textPen(character: 2, verticalOffset: 20) }
        append(after: cadence) { self.textPen(character: 2, down: false, verticalOffset: 20) }
        append(after: cadence) {
            self.check(self.textView.bridgeScrolls > self.textScrollBefore && self.textView.trace.count == self.textTraceBefore, "文字拖选结束后下次滑动恢复滚动")
            self.output.release(); self.textTraceBefore = self.textView.trace.count
            self.textScrollBefore = self.textView.bridgeScrolls
            self.textPen(character: 2); self.textPen(character: 2, down: false)
        }
        append(after: cadence) {
            self.textPen(character: 2, horizontalOffset: 6)
            self.textPen(character: 2, down: false, horizontalOffset: 6)
        }
        append(after: cadence) {
            let trace = Array(self.textView.trace.dropFirst(self.textTraceBefore))
            let selection = self.textView.selectedRange()
            self.check(trace.contains { $0.hasPrefix("down count=2") } &&
                (self.textView.string as NSString).substring(with: selection) == "alpha", "浏览偏移6点的双击仍实际选词")
            self.textPen(character: 2, horizontalOffset: 8)
            self.textPen(character: 2, down: false, horizontalOffset: 8)
        }
        append(after: cadence) {
            let trace = Array(self.textView.trace.dropFirst(self.textTraceBefore))
            self.check(trace.contains { $0.hasPrefix("down count=3") } && self.textView.selectedRange().length >= "alpha beta gamma".count,
                "浏览偏移8点的三击仍实际选段")
            self.check(self.textView.bridgeScrolls == self.textScrollBefore, "偏移连续点按不混发滚动")
            self.output.release(); self.output.longPress.enabled = false
            self.output.applicationProfiles.set(.pointer, for: id, name: "本地事件验收")
            self.pen(); self.pen(0.5 + 6 / 719.0); self.pen(down: false)
        }
        append(after: cadence) { self.pen(0.5 + 6 / 719.0); self.pen(0.5 + 6 / 719.0, down: false) }
        append(after: cadence) {
            self.check(Array(self.window.receivedDownClickCounts.suffix(2)) == [1, 2], "点按中轻微移动仍可接续双击计数")
            self.output.release(); self.output.applicationProfiles.set(.drawing, for: id, name: "本地事件验收")
            self.output.tabletEnabled = true
            self.pen(); self.pen(0.5 + 6 / 719.0); self.pen(down: false)
        }
        append(after: cadence) { self.pen(0.5 + 6 / 719.0); self.pen(0.5 + 6 / 719.0, down: false) }
        append(after: cadence) {
            self.check(Array(self.window.receivedDownClickCounts.suffix(2)) == [1, 1], "绘画保留原位移判定，不使用连续点按额外容差")
            self.finish()
        }
        runNext()
    }
    private func titlePen(offset: CGFloat = 0, down: Bool = true) {
        let desktop = NSPoint(x: originalFrame.midX + offset, y: originalFrame.maxY - 10)
        let bounds = output.mapping.bounds
        let top = NSScreen.screens.first!.frame.maxY
        pen((desktop.x - bounds.minX) / (bounds.width - 1), (top - desktop.y - bounds.minY) / (bounds.height - 1), down: down)
    }
    private func textPen(character: Int, down: Bool = true, verticalOffset: CGFloat = 0, horizontalOffset: CGFloat = 0) {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: character)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let local = NSPoint(x: rect.midX + textView.textContainerInset.width, y: rect.midY + textView.textContainerInset.height)
        let windowPoint = textView.convert(local, to: nil)
        let desktop = window.convertPoint(toScreen: windowPoint)
        let top = NSScreen.screens.first!.frame.maxY
        let bounds = output.mapping.bounds
        pen((desktop.x - bounds.minX + horizontalOffset) / (bounds.width - 1), (top - desktop.y - bounds.minY + verticalOffset) / (bounds.height - 1), down: down)
    }
    private func pen(_ x: Double = 0.5, _ y: Double = 0.5, down: Bool = true) {
        output.receive(Sample(x: x, y: y, touching: down, inRange: true,
                              pressure: 4096, tiltX: 30, tiltY: -20, positionValid: true))
    }
    private func append(after delay: Double = 0.2, _ step: @escaping () -> Void) { steps.append((delay, step)) }
    private func runNext() {
        guard !steps.isEmpty else { return }
        let next = steps.removeFirst()
        // Text controls run nested tracking loops; common-mode timers keep the synthetic pen moving.
        let timer = Timer(timeInterval: next.0, repeats: false) { _ in
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
        RunLoop.main.add(timer, forMode: .common)
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
            "textTrace": textView.trace, "textSelectionLocation": textView.selectedRange().location, "textSelectionLength": textView.selectedRange().length,
            "AXTrusted": AXIsProcessTrusted(), "postAccess": CGPreflightPostEventAccess(),
            "postedDown": output.downCount, "postedUp": output.upCount, "postedScroll": output.scrollEventCount,
            "warpError": output.lastWarpError.rawValue, "windowTrace": window.trace, "receivedDownClickCounts": window.receivedDownClickCounts,
            "originalWindowFrame": NSStringFromRect(originalFrame), "windowMovable": window.isMovable,
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

private final class EventCheckTextView: NSTextView {
    var trace: [String] = []
    var bridgeScrolls = 0
    override func scrollWheel(with event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == bridgeEventTag { bridgeScrolls += 1 }
        super.scrollWheel(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        trace.append("down count=\(event.clickCount) point=\(event.locationInWindow) buttons=\(NSEvent.pressedMouseButtons) number=\(event.eventNumber)")
        super.mouseDown(with: event)
        trace.append("after down range=\(selectedRange()) buttons=\(NSEvent.pressedMouseButtons)")
    }
    override func mouseDragged(with event: NSEvent) {
        trace.append("drag point=\(event.locationInWindow) buttons=\(NSEvent.pressedMouseButtons) number=\(event.eventNumber)")
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        trace.append("up point=\(event.locationInWindow) range=\(selectedRange())")
        super.mouseUp(with: event)
    }
}

private final class EventCheckScrollRegion: NSView {
    var scrolls = 0
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.scrollArea)
    }
    required init?(coder: NSCoder) { fatalError("Local diagnostic only") }
    override func scrollWheel(with event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == bridgeEventTag { scrolls += 1 }
    }
}

private final class EventCheckWindow: NSWindow {
    var trace: [String] = []
    var receivedDownClickCounts: [Int] = []
    override func sendEvent(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == bridgeEventTag &&
            [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
            trace.append("type=\(event.type.rawValue) count=\(event.clickCount) point=\(event.locationInWindow) frame=\(frame) buttons=\(NSEvent.pressedMouseButtons)")
            if event.type == .leftMouseDown { receivedDownClickCounts.append(event.clickCount) }
        }
        super.sendEvent(event)
    }
}
