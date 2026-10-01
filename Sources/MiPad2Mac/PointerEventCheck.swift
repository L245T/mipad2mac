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
    private var fallbackDownBefore = 0
    private var fallbackScrollBefore = 0
    private var fallbackRightBefore = 0
    private var diagnosticMessages: [String] = []
    private var fallbackFrame = NSRect.zero
    private var hitUnavailable = false
    private var windowUnavailable = false
    private var profileScrollBefore = 0
    private var profileDownBefore = 0
    private var profileUpBefore = 0
    private var momentumBefore = 0
    private var coastCursor = CGPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        originalCursor = CGEvent(source: nil)?.location ?? .zero
        defaults = UserDefaults(suiteName: suite)!
        output = PointerOutput(defaults: defaults, observeApplications: false, diagnosticOwnWindow: true,
                               diagnosticHitUnavailable: { [weak self] in self?.hitUnavailable ?? false },
                               diagnosticWindowUnavailable: { [weak self] in self?.windowUnavailable ?? false })
        output.momentumEnabled = false
        output.longPress.enabled = false
        output.tabletEnabled = true
        let id = Bundle.main.bundleIdentifier ?? "org.mipad2mac.app"
        window = EventCheckWindow(contentRect: view.bounds, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MiPad2Mac 本地事件验收"; window.contentView = view
        view.setAccessibilityElement(true); view.setAccessibilityRole(.scrollArea)
        textView.string = "alpha beta gamma\nsecond paragraph\n"
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.isEditable = false; textView.isSelectable = true
        view.addSubview(textView)
        // Whole-desktop titlebar checks use the primary screen; do not center on the pen's secondary display.
        let primary = NSScreen.screens.first!.visibleFrame
        window.setFrameOrigin(NSPoint(x: primary.midX - window.frame.width / 2,
                                      y: primary.midY - window.frame.height / 2))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let frame = window.convertToScreen(view.bounds)
        let top = NSScreen.screens.first!.frame.maxY
        output.mapping = Mapping(bounds: CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height))
        view.record = { print($0) }
        output.longPressDiagnostic = { [weak self] message in
            print(message)
            if self?.diagnosticMessages.count ?? 200 < 200 { self?.diagnosticMessages.append(message) }
        }
        // The native show animation briefly changes WindowServer bounds; start after it settles.
        append(after: 0.6) {
            self.check(self.output.configuredProfiles.map(\.bundleID) == ["com.adobe.photoshop"], "初始列表只含可见Photoshop家族兼容例外")
            self.output.removeApplicationProfile(bundleID: "com.adobe.photoshop")
            self.pen()
        }
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
        }
        // A restored AppKit frame reaches WindowServer asynchronously.
        append(after: 0.08) {
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
            self.output.release(); self.output.tabletEnabled = false
            self.output.applicationProfiles.set(.browse, for: id, name: "本地事件验收")
            self.output.longPress.enabled = true
            self.view.setAccessibilityRole(.unknown)
            self.fallbackDownBefore = self.output.downCount
            self.fallbackScrollBefore = self.view.bridgeScrolls
            self.fallbackRightBefore = self.view.receivedRightClicks
            self.pen()
        }
        append(after: 0.04) { self.pen(0.5, 0.6) }
        append(after: 0.08) { self.pen(0.5, 0.7); self.pen(down: false) }
        append {
            self.check(self.view.bridgeScrolls > self.fallbackScrollBefore, "未知区域不需按钮或修饰键就能滚动")
            self.check(self.output.downCount == self.fallbackDownBefore && self.view.receivedRightClicks == self.fallbackRightBefore, "未知区域滚动没有左键选择或右键")
            self.fallbackScrollBefore = self.view.bridgeScrolls
            self.pen(); self.pen(0.5, 0.6); self.pen(down: false)
        }
        append {
            self.check(self.view.bridgeScrolls > self.fallbackScrollBefore, "抬笔后下一笔继续滚动，不是一次性动作")
            self.output.release(); self.pen(); self.pen(down: false)
        }
        append(after: cadence) {
            self.check(self.output.downCount == self.fallbackDownBefore + 1, "未知区域轻点仍完整单击")
            self.fallbackScrollBefore = self.view.bridgeScrolls
            self.pen(); self.pen(0.55); self.pen(down: false)
        }
        append {
            self.check(self.view.receivedDragClickCounts.last == 2 && self.view.bridgeScrolls == self.fallbackScrollBefore, "未知区域双击按住拖动仍选择，不滚动")
            self.output.release(); self.pen()
        }
        append(after: 0.8) { self.pen(down: false) }
        append {
            self.check(self.view.receivedRightClicks == self.fallbackRightBefore + 1, "未知区域静止长按仍触发右键")
            self.output.release(); self.output.longPress.enabled = false
            self.fallbackDownBefore = self.output.downCount
            self.fallbackScrollBefore = self.view.bridgeScrolls
            self.output.release(); self.hitUnavailable = true
            self.fallbackScrollBefore = self.view.bridgeScrolls
            self.fallbackDownBefore = self.output.downCount
            self.pen(); self.pen(0.5, 0.6); self.pen(down: false)
        }
        append {
            self.check(self.view.bridgeScrolls > self.fallbackScrollBefore && self.output.downCount == self.fallbackDownBefore, "AX命中完全不可用时按真实窗口连续滚动")
            self.output.release(); self.output.longPress.enabled = true
            self.fallbackRightBefore = self.view.receivedRightClicks
            self.pen()
        }
        append(after: 0.8) { self.pen(down: false) }
        append {
            self.check(self.view.receivedRightClicks == self.fallbackRightBefore + 1, "AX不可用时长按用原窗口身份核对")
            self.output.release(); self.output.longPress.enabled = false
            self.fallbackFrame = self.window.frame
            self.pen()
        }
        append(after: 0.04) { self.pen(0.5, 0.6) }
        append(after: 0.08) {
            self.fallbackScrollBefore = self.view.bridgeScrolls
            self.window.setFrameOrigin(NSPoint(x: self.fallbackFrame.minX + 30, y: self.fallbackFrame.minY))
        }
        append(after: 0.08) { self.pen(0.5, 0.7); self.pen(down: false) }
        append {
            self.check(self.view.bridgeScrolls == self.fallbackScrollBefore && self.diagnosticMessages.contains { $0.contains("目标窗口改变或被遮挡") }, "未知窗口移动后取消滚动，不继续投递旧锚点")
            self.window.setFrame(self.fallbackFrame, display: true)
        }
        append {
            self.output.release(); self.output.applicationProfiles.set(.browse, for: id, name: "本地事件验收")
            self.fallbackDownBefore = self.output.downCount
            self.fallbackScrollBefore = self.view.bridgeScrolls
            self.output.release()
            self.originalMapping = self.output.mapping; self.originalFrame = self.window.frame
            let screen = NSScreen.screens.first!.frame
            self.output.mapping = Mapping(bounds: CGRect(x: screen.minX, y: 0, width: screen.width, height: screen.height))
            self.fallbackScrollBefore = self.view.bridgeScrolls
            self.titlePen()
        }
        append(after: 0.04) { self.titlePen(offset: 10) }
        append(after: 0.04) { self.titlePen(offset: 40) }
        append(after: 0.08) { self.titlePen(offset: 40, down: false) }
        append {
            self.check(abs(self.window.frame.minX - self.originalFrame.minX) > 20 && self.view.bridgeScrolls == self.fallbackScrollBefore, "AX不可用时未知窗口顶部仍可拖动")
            self.window.setFrame(self.originalFrame, display: true); self.output.mapping = self.originalMapping
            self.output.release(); self.output.applicationProfiles.set(.drawing, for: id, name: "本地事件验收")
            self.output.tabletEnabled = true
            self.fallbackDownBefore = self.output.downCount
            self.fallbackScrollBefore = self.view.bridgeScrolls
            self.pen(); self.pen(0.5, 0.6); self.pen(down: false)
        }
        append {
            self.check(self.output.downCount == self.fallbackDownBefore + 1 && self.view.bridgeScrolls == self.fallbackScrollBefore, "AX不可用仍保留绘画模式即时落笔")
            self.output.release(); self.output.applicationProfiles.set(.pointer, for: id, name: "本地事件验收")
            self.fallbackDownBefore = self.output.downCount
            self.pen(); self.pen(0.5, 0.6); self.pen(down: false)
        }
        append {
            self.check(self.output.downCount == self.fallbackDownBefore + 1 && self.view.bridgeScrolls == self.fallbackScrollBefore, "普通指针应用不会因未知区域自动变滚动")
            self.output.release(); self.hitUnavailable = false
            self.view.setAccessibilityRole(.scrollArea)
            self.output.applicationProfiles.set(.browse, for: id, name: "本地事件验收")
            self.output.tabletEnabled = false; self.output.momentumEnabled = true
            self.fallbackDownBefore = self.output.downCount
            self.momentumBefore = self.view.receivedMomentumPhases.count
            self.pen()
        }
        append(after: 0.03) { self.pen(0.5, 0.55) }
        append(after: 0.03) { self.pen(0.5, 0.68) }
        append(after: 0.01) { self.pen(down: false); self.coastCursor = CGEvent(source: nil)?.location ?? .zero }
        append(after: 0.08) {
            let phases = Array(self.view.receivedMomentumPhases.dropFirst(self.momentumBefore))
            self.check(self.output.momentumActive && phases.contains(1) && phases.contains(2), "已识别内容抬笔后惯性开始与继续实际到达")
            self.check(self.view.receivedAppKitMomentumPhases.contains(NSEvent.Phase.began.rawValue), "目标收到AppKit惯性阶段")
            let cursor = CGEvent(source: nil)?.location ?? .zero
            self.check(hypot(cursor.x - self.coastCursor.x, cursor.y - self.coastCursor.y) < 2, "惯性期间不把光标拉回落笔锚点")
            self.check(self.output.downCount == self.fallbackDownBefore, "惯性没有左键点击或文字拖选")
        }
        append(after: 3.1) {
            self.check(!self.output.momentumActive && self.view.receivedMomentumPhases.last == 3, "惯性自然减速结束实际到达")
            let expected = self.output.mapping.point(x: 0.5, y: 0.5)
            self.check(self.view.receivedMomentumAnchors.dropFirst(self.momentumBefore).allSatisfy { hypot($0.x - expected.x, $0.y - expected.y) < 2 }, "惯性固定到原内容位置")
            self.output.release(); self.hitUnavailable = true
            self.momentumBefore = self.view.receivedMomentumPhases.count; self.pen()
        }
        append(after: 0.03) { self.pen(0.5, 0.55) }
        append(after: 0.03) { self.pen(0.5, 0.68) }
        append(after: 0.01) { self.pen(down: false) }
        append(after: 0.05) {
            self.check(self.output.momentumActive && self.view.receivedMomentumPhases.count > self.momentumBefore, "未知区域抬笔后同样进入惯性")
            self.fallbackDownBefore = self.output.downCount
            self.pen(); self.pen(down: false)
            self.check(!self.output.momentumActive, "再次落笔同步停止惯性提交")
        }
        // Already submitted WindowServer events may arrive asynchronously; measure after they drain.
        append(after: 0.05) {
            self.momentumBefore = self.view.receivedMomentumPhases.filter { $0 != 3 }.count
        }
        append(after: 0.1) {
            self.check(!self.output.momentumActive && self.view.receivedMomentumPhases.filter { $0 != 3 }.count == self.momentumBefore, "打断后没有继续到达的惯性滚动帧")
            self.check(self.output.downCount == self.fallbackDownBefore + 1, "打断惯性后轻点仍完整点击")
            self.output.release(); self.fallbackFrame = self.window.frame; self.pen()
        }
        append(after: 0.03) { self.pen(0.5, 0.55) }
        append(after: 0.03) { self.pen(0.5, 0.68) }
        append(after: 0.01) { self.pen(down: false) }
        append(after: 0.05) { self.window.setFrameOrigin(NSPoint(x: self.fallbackFrame.minX + 30, y: self.fallbackFrame.minY)) }
        append(after: 0.08) { self.momentumBefore = self.view.receivedMomentumPhases.count }
        append(after: 0.1) {
            self.check(!self.output.momentumActive && self.view.receivedMomentumPhases.count == self.momentumBefore, "窗口移动后停止惯性，不向旧区域继续滚动")
            self.window.setFrame(self.fallbackFrame, display: true)
        }
        append {
            self.output.release(); self.output.momentumEnabled = false
            self.momentumBefore = self.view.receivedMomentumPhases.filter { $0 != 3 }.count; self.pen()
        }
        append(after: 0.03) { self.pen(0.5, 0.55) }
        append(after: 0.03) { self.pen(0.5, 0.68) }
        append(after: 0.01) { self.pen(down: false) }
        append(after: 0.08) {
            self.check(!self.output.momentumActive && self.view.receivedMomentumPhases.filter { $0 != 3 }.count == self.momentumBefore, "关闭惯性恢复抬笔即停")
            self.output.release(); self.output.momentumEnabled = true
            self.momentumBefore = self.view.receivedMomentumPhases.count; self.pen()
        }
        append(after: 0.03) { self.pen(0.6, 0.5) }
        append(after: 0.03) { self.pen(0.7, 0.5) }
        append(after: 0.01) { self.pen(down: false) }
        append(after: 0.08) {
            let axes = Array(self.view.receivedMomentumAxes.dropFirst(self.momentumBefore))
            self.check(self.output.momentumActive && axes.contains { $0.x != 0 } && axes.allSatisfy { $0.y == 0 }, "横向惯性只沿原横向滚动")
            self.output.release()
        }
        // Drain previously submitted horizontal momentum before counting a stopped vertical contact.
        append(after: 0.05) {
            self.momentumBefore = self.view.receivedMomentumPhases.filter { $0 != 3 }.count
            self.pen()
        }
        append(after: 0.03) { self.pen(0.5, 0.65) }
        append(after: 0.12) { self.pen(0.5, 0.65) }
        append(after: 0.12) { self.pen(0.5, 0.65) }
        append(after: 0.01) { self.pen(down: false) }
        append(after: 0.08) {
            self.check(!self.output.momentumActive && self.view.receivedMomentumPhases.filter { $0 != 3 }.count == self.momentumBefore, "停稳后抬笔不产生惯性")
            self.output.momentumEnabled = false; self.output.longPress.enabled = false
            self.output.removeApplicationProfile(bundleID: id)
            self.hitUnavailable = true
            self.check(self.output.configuredProfiles.isEmpty && self.output.applicationProfiles.mode(for: id) == .browse,
                       "删除新旧记录后回到默认浏览且不复活列表")
            self.fallbackScrollBefore = self.view.bridgeScrolls; self.profileDownBefore = self.output.downCount
            self.pen(); self.pen(0.5, 0.6)
        }
        append {
            self.check(self.view.bridgeScrolls > self.fallbackScrollBefore && self.output.downCount == self.profileDownBefore,
                       "空配置且长按关闭时未知普通窗口仍收到滚动而不选字")
            self.output.setApplicationProfileMode(.pointer, for: id, name: "本地事件验收")
            self.profileScrollBefore = self.output.scrollEventCount
            self.pen(0.5, 0.7)
            self.check(self.output.scrollEventCount == self.profileScrollBefore && self.output.downCount == self.profileDownBefore,
                       "滚动中修改模式安全释放，同次接触不变成左键拖动")
            self.pen(down: false)
            self.pen(); self.pen(0.55, 0.55)
        }
        append {
            self.check(self.output.downCount == self.profileDownBefore + 1,
                       "模式切换后新接触采用显式指针")
            self.profileUpBefore = self.output.upCount
            self.output.removeApplicationProfile(bundleID: id)
            self.check(self.output.upCount == self.profileUpBefore + 1, "指针接触期间删除配置实际释放左键")
            self.profileDownBefore = self.output.downCount; self.profileScrollBefore = self.output.scrollEventCount
            self.pen(0.6, 0.6); self.pen(down: false)
            self.check(self.output.downCount == self.profileDownBefore && self.output.scrollEventCount == self.profileScrollBefore,
                       "删除配置后的剩余接触不混发点击或滚动")
            self.hitUnavailable = false; self.windowUnavailable = true
            self.fallbackScrollBefore = self.view.bridgeScrolls
            self.pen(); self.pen(0.55, 0.55); self.pen(down: false)
        }
        append {
            self.check(self.output.downCount == self.profileDownBefore + 1 && self.view.bridgeScrolls == self.fallbackScrollBefore,
                       "即使AX命中内容，无普通窗口身份也不会误启默认滚动")
            self.windowUnavailable = false; self.hitUnavailable = true
            self.output.selectProfile("com.example.menu-context")
            self.output.setApplicationProfileMode(.drawing, for: id, name: "本地事件验收")
            self.check(self.output.profileID == "com.example.menu-context" && self.output.configuredProfiles.first?.mode == .drawing,
                       "逐行设置模式不覆盖当前应用或HID菜单上下文")
            self.output.addApplicationProfile(bundleID: id.uppercased(), name: "本地事件验收")
            self.check(self.output.configuredProfiles.count == 1 && self.output.configuredProfiles.first?.mode == .drawing,
                       "重复添加应用保留绘画选择并按ID去重")
            self.output.removeApplicationProfile(bundleID: id)
            self.check(self.output.profileID == "com.example.menu-context" && self.output.configuredProfiles.isEmpty,
                       "删除另一行不改变当前应用上下文或自动登记该应用")
            self.output.removeApplicationProfile(bundleID: "com.example.menu-context")
            self.check(self.output.selectedProfileID == nil, "删除旧选择记录清除失效上下文")
            self.output.addApplicationProfile(bundleID: id, name: "本地事件验收")
            self.output.momentumEnabled = true
            self.pen()
        }
        append(after: 0.03) { self.pen(0.5, 0.55) }
        append(after: 0.03) { self.pen(0.5, 0.68) }
        append(after: 0.01) { self.pen(down: false) }
        append(after: 0.08) {
            self.check(self.output.momentumActive, "配置删除验收前已进入惯性滚动")
            self.output.removeApplicationProfile(bundleID: id)
            self.check(!self.output.momentumActive, "删除应用配置同步停止惯性提交")
        }
        append(after: 0.05) { self.momentumBefore = self.view.receivedMomentumPhases.filter { $0 != 3 }.count }
        append(after: 0.1) {
            self.check(self.view.receivedMomentumPhases.filter { $0 != 3 }.count == self.momentumBefore,
                       "删除配置后系统队列排空，无继续到达的惯性帧")
            self.output.momentumEnabled = false
            self.output.changeLongPress {
                $0.enabled = true; $0.compatibilityEnabled = true
                $0.compatibilityApplications = [id.uppercased(): "本地事件验收"]
            }
            self.fallbackRightBefore = self.view.receivedRightClicks
            self.pen()
        }
        append(after: 0.8) { self.pen(down: false) }
        append {
            self.check(self.view.receivedRightClicks == self.fallbackRightBefore + 2,
                       "AX完全不可用时按真实窗口应用匹配名单，收到两次完整兼容右键")
            self.output.changeLongPress { $0.compatibilityApplications = ["com.example.other": "Other"] }
            self.fallbackRightBefore = self.view.receivedRightClicks
            self.pen()
        }
        append(after: 0.8) { self.pen(down: false) }
        append {
            self.check(self.view.receivedRightClicks == self.fallbackRightBefore + 1,
                       "AX不可用且应用不在兼容名单时仍只发送一次右键")
            self.output.changeLongPress { $0.compatibilityApplications = [id: "本地事件验收"] }
            self.output.setApplicationProfileMode(.drawing, for: id, name: "本地事件验收")
            self.fallbackRightBefore = self.view.receivedRightClicks; self.profileDownBefore = self.output.downCount
            self.pen()
        }
        append(after: 0.8) { self.pen(0.55, 0.55); self.pen(down: false) }
        append {
            self.check(self.view.receivedRightClicks == self.fallbackRightBefore && self.output.downCount == self.profileDownBefore + 1,
                       "AX不可用且在兼容名单的绘画应用仍即时落笔、不触发右键")
            self.output.removeApplicationProfile(bundleID: id)
            self.output.changeLongPress { $0.enabled = false }
            self.hitUnavailable = false
            self.fallbackFrame = self.window.frame
            self.pen()
        }
        append(after: 0.04) { self.pen(0.5, 0.6) }
        append(after: 0.08) {
            self.profileScrollBefore = self.output.scrollEventCount; self.fallbackScrollBefore = self.view.bridgeScrolls
            self.window.setFrameOrigin(NSPoint(x: self.fallbackFrame.minX + 30, y: self.fallbackFrame.minY))
        }
        append(after: 0.08) {
            self.pen(0.5, 0.65)
        }
        append(after: 0.08) { self.pen(0.5, 0.7); self.pen(down: false) }
        append {
            print("已识别滚动移窗计数：提交 \(self.profileScrollBefore)→\(self.output.scrollEventCount)，接收 \(self.fallbackScrollBefore)→\(self.view.bridgeScrolls)")
            self.check(self.output.scrollEventCount == self.profileScrollBefore && self.view.bridgeScrolls == self.fallbackScrollBefore,
                       "已识别内容的窗口移动后同样取消直接滚动，不向旧锚点投递")
            self.window.setFrame(self.fallbackFrame, display: true)
        }
        append(after: 0.08) {
            self.output.setDefaultApplicationMode(.pointer)
            self.profileDownBefore = self.output.downCount; self.profileUpBefore = self.output.upCount
            self.pen()
            self.check(self.output.downCount == self.profileDownBefore + 1, "未配置应用采用全局指针默认")
            self.output.setDefaultApplicationMode(.drawing)
            self.check(self.output.upCount == self.profileUpBefore + 1, "修改默认模式释放实际左键")
            self.pen(0.55, 0.55); self.pen(down: false)
            self.check(self.output.downCount == self.profileDownBefore + 1, "修改默认后的同次接触不补发新点击")
            self.check(PenApplicationPreferences(defaults: self.defaults).defaultApplicationMode == .drawing,
                       "默认模式通过隔离UserDefaults恢复")
            self.pen()
        }
        append {
            self.check(self.output.downCount == self.profileDownBefore + 2, "抬笔后的新接触采用绘画默认")
            self.output.setDefaultApplicationMode(.browse)
            self.pen(0.55, 0.55); self.pen(down: false)
            self.output.momentumEnabled = true
            self.pen()
        }
        append(after: 0.03) { self.pen(0.5, 0.55) }
        append(after: 0.03) { self.pen(0.5, 0.68) }
        append(after: 0.01) { self.pen(down: false) }
        append(after: 0.08) {
            self.check(self.output.momentumActive, "默认浏览应用抬笔后进入惯性")
            self.output.setDefaultApplicationMode(.pointer)
            self.check(!self.output.momentumActive, "修改默认模式立即停止惯性")
            self.momentumBefore = self.view.receivedMomentumPhases.filter { $0 != 3 }.count
        }
        append(after: 0.08) {
            self.check(self.view.receivedMomentumPhases.filter { $0 != 3 }.count == self.momentumBefore,
                       "默认修改后不继续投递惯性帧")
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
        let top = NSScreen.screens.first!.frame.maxY
        let frame = window.frame
        let receiver = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        guard receiver.contains(output.mapping.point(x: x, y: y)) else {
            blocked = "测试坐标离开本程序接收窗口，停止发送事件"
            finish(); return
        }
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
            "clickCounts": view.receivedClickCounts, "scrollPhases": view.receivedScrollPhases, "momentumPhases": view.receivedMomentumPhases, "appKitMomentumPhases": view.receivedAppKitMomentumPhases,
            "rightClicks": view.receivedRightClicks, "tabletContacts": view.receivedTabletContacts,
            "textTrace": textView.trace, "textSelectionLocation": textView.selectedRange().location, "textSelectionLength": textView.selectedRange().length,
            "AXTrusted": AXIsProcessTrusted(), "postAccess": CGPreflightPostEventAccess(),
            "postedDown": output.downCount, "postedUp": output.upCount, "postedScroll": output.scrollEventCount,
            "warpError": output.lastWarpError.rawValue, "windowTrace": window.trace, "receivedDownClickCounts": window.receivedDownClickCounts,
            "originalWindowFrame": NSStringFromRect(originalFrame), "windowMovable": window.isMovable,
            "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown", "diagnostics": diagnosticMessages]
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
