import AppKit
import ApplicationServices
import MiPadCore
import UniformTypeIdentifiers

final class PointerOutput {
    // Experimental event-stream identity only; this does not register an OS tablet driver.
    // Keep IDs consistent between proximity and pointer events; never impersonate Wacom.
    let tabletID: Int64 = 0x4d49
    var tabletEnabled = false
    private var inProximity = false
    private var currentSample: Sample?
    var proximityCount = 0
    var didPost: () -> Void = {}
    var longPressDiagnostic: (String) -> Void = { _ in }
    private var gesture = LongPressGesture()
    let longPress: LongPressPreferences
    let navigation: PenNavigationPreferences
    private var lastExternalApplication: NSRunningApplication?
    var selectedProfileID: String?
    private var selectedProfileName: String?
    private var contactMode = PenNavigationMode.pointer
    var scrollEventCount = 0
    var scrollGestureCount = 0
    private var postedScrollAnchor: CGPoint?

    var profileID: String? { selectedProfileID ?? lastExternalApplication?.bundleIdentifier }
    var profileName: String { selectedProfileName ?? lastExternalApplication?.localizedName ?? "请先选择应用" }
    var profileExcluded: Bool { profileID.map { longPress.excludes($0) } ?? false }
    var profileMode: PenNavigationMode { navigation.mode(for: profileID, excluded: profileExcluded) }
    var profileApplications: [String: String] {
        var apps = navigation.applications
        if let id = profileID { apps[id] = profileName }
        return apps
    }
    func selectProfile(_ id: String) {
        let name = profileApplications[id] ?? id
        selectedProfileID = id
        selectedProfileName = name
    }
    func changeNavigation(_ mode: PenNavigationMode) {
        guard let id = profileID, !(mode == .browse && profileExcluded) else { return }
        release()
        navigation.set(mode, for: id, name: profileName)
        longPressDiagnostic("应用默认模式：\(profileName) → \(mode.title)；已结束当前接触")
    }
    func chooseNavigationApplication() {
        release()
        let panel = NSOpenPanel()
        panel.title = "选择笔输入模式的应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        selectedProfileID = id
        selectedProfileName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        navigation.set(navigation.mode(for: id), for: id, name: profileName)
    }
    private var longPressTimer: Timer?
    private var applicationObserver: NSObjectProtocol?
    private var compatibilityContact = false
    private var candidateTarget: pid_t?
    private var candidateFrontmost: pid_t?
    private var contactSample: Sample?
    private var deferredContact = false
    private var pressLocation = CGPoint.zero
    private var postedLeft = false
    private var postedRight = false
    private var clicks = ClickSequence()
    private var contactStarted: TimeInterval = 0
    var rightClickCount = 0
    var rightEventCount = 0

    init(defaults: UserDefaults = .standard, observeApplications: Bool = true) {
        longPress = LongPressPreferences(defaults: defaults)
        navigation = PenNavigationPreferences(defaults: defaults)
        guard observeApplications else { return }
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = app
        }
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.lastExternalApplication = app
                self.selectedProfileID = nil; self.selectedProfileName = nil
            }
            // An immediate click may activate its own target. Other activation cancels the contact.
            if app.processIdentifier == self.candidateTarget {
                self.candidateFrontmost = app.processIdentifier
                if self.gesture.isIdle { self.clicks.reset() }
            } else {
                self.longPressDiagnostic("输入结束：前台应用切换")
                self.release()
            }
        }
    }
    deinit {
        longPressTimer?.invalidate()
        if let applicationObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver) }
    }
    // AX hit testing identifies the application under the pen, including inactive windows.
    // Unknown targets take the immediate path; never guess that they are safe to defer.
    private func target(at point: CGPoint) -> NSRunningApplication? {
        var element: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
        guard result == .success, let element else {
            longPressDiagnostic("长按目标识别失败：AX \(result.rawValue)")
            return nil
        }
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else {
            longPressDiagnostic("长按目标进程识别失败：AX \(pidResult.rawValue)")
            return nil
        }
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.bundleIdentifier == nil { longPressDiagnostic("长按目标没有应用标识：PID \(pid)") }
        return app
    }
    func changeLongPress(_ edit: (LongPressPreferences) -> Void) {
        release(); edit(longPress)
    }
    func addExcludedApplication(compatibility: Bool = false) {
        release()
        let panel = NSOpenPanel()
        panel.title = compatibility ? "选择使用右键兼容模式的应用" : "选择不使用长按右键的绘画应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        changeLongPress { settings in
            var apps = compatibility ? settings.compatibilityApplications : settings.exclusions
            apps[id] = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            if compatibility { settings.compatibilityApplications = apps }
            else { settings.exclusions = apps }
        }
    }
    func resetConnection() { release(); gesture.reset() }
    private func scheduleLongPress() {
        guard longPressTimer == nil, let deadline = gesture.deadline else { return }
        let timer = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.longPressTimer = nil
            guard self.gesture.hasScheduledClick else { return }
            guard let candidateTarget = self.candidateTarget,
                  self.target(at: self.pressLocation)?.processIdentifier == candidateTarget,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == self.candidateFrontmost else {
                self.longPressDiagnostic("长按取消：到时目标应用或前台应用已变化/无法识别")
                self.release(); return
            }
            self.emit(self.gesture.fire(now: ProcessInfo.processInfo.systemUptime, compatibility: self.compatibilityContact))
            if self.gesture.hasScheduledClick { self.scheduleLongPress() }
        }
        longPressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func emit(_ events: [PointerEvent]) {
        for planned in events {
            if planned.action == .down {
                clickCount = clicks.begin(at: planned.point, now: contactStarted, interval: NSEvent.doubleClickInterval)
            }
            if planned.action == .drag { clicks.drag(to: planned.point) }
            if planned.action == .rightDown { clicks.reset() }
            if !send(planned.action, at: planned.point) {
                clicks.reset()
                // Release only buttons we actually submitted and suppress this contact after a failed post setup.
                let cancelled = gesture.cancelNavigation()
                emitScroll(cancelled.scroll)
                if postedLeft { _ = send(.up, at: lastPoint) }
                if postedRight { _ = send(.rightUp, at: lastPoint) }
                break
            }
        }
    }
    var lastPoint = CGPoint.zero
    private var lastTabletPoint = CGPoint.zero
    var mapping = Mapping(bounds: .zero)
    var clickCount: Int64 = 1
    var downCount = 0
    var upCount = 0
    var moveCount = 0
    var dragCount = 0
    var lastWarpError: CGError = .success
    let source = CGEventSource(stateID: .privateState)
    func receive(_ sample: Sample) {
        currentSample = sample
        let contact = sample.touching && sample.inRange && !sample.eraser
        if gesture.isIdle && contact && sample.positionValid {
            contactStarted = ProcessInfo.processInfo.systemUptime
            pressLocation = mapping.point(x: sample.x, y: sample.y)
            let frontmost = NSWorkspace.shared.frontmostApplication
            let frontmostExcluded = frontmost?.bundleIdentifier.map { longPress.excludes($0) } ?? false
            let targetApp = (longPress.enabled || navigation.hasBrowseApplications) && !frontmostExcluded ? target(at: pressLocation) : nil
            candidateTarget = targetApp?.processIdentifier
            candidateFrontmost = frontmost?.processIdentifier
            contactMode = navigation.mode(for: targetApp?.bundleIdentifier,
                    excluded: frontmostExcluded || (targetApp?.bundleIdentifier.map { longPress.excludes($0) } ?? false))
            deferredContact = longPress.enabled && !frontmostExcluded
                && (targetApp?.bundleIdentifier.map { !longPress.excludes($0) } ?? false)
            compatibilityContact = deferredContact && (targetApp?.bundleIdentifier.map { longPress.usesCompatibility(for: $0) } ?? false)
            if longPress.enabled {
                longPressDiagnostic("长按判定：目标 \(targetApp?.bundleIdentifier ?? "未知")，前台 \(frontmost?.bundleIdentifier ?? "未知")，\(deferredContact ? "开始计时" : "即时左键（排除或目标未识别）")")
            }
        }
        if !contact && gesture.isIdle {
            let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            contactMode = navigation.mode(for: id, excluded: id.map { longPress.excludes($0) } ?? false)
        }
        if contactMode == .browse && inProximity { sendProximity(false, at: lastPoint) }
        if tabletEnabled && contactMode == .pointer && sample.inRange && sample.positionValid && !sample.eraser && !inProximity {
            sendProximity(true, at: mapping.point(x: sample.x, y: sample.y))
        }
        if contact { contactSample = sample }
        // A deferred tap is emitted on lift; retain the last actual contact's tablet fields.
        if !contact && gesture.isPending { currentSample = contactSample }
        let wasPending = gesture.isPending
        let result = gesture.consumeNavigation(sample, mapping: mapping, now: ProcessInfo.processInfo.systemUptime,
                                     enabled: deferredContact, delay: longPress.delay, drawing: tabletEnabled,
                                     jitterFilter: longPress.jitterFilter, navigation: contactMode)
        let events = result.pointer
        if wasPending && !gesture.isPending {
            longPressDiagnostic(events.contains { $0.action == .drag }
                ? "长按取消：移动超出抖动过滤范围（\(longPress.jitterFilter.title)，\(longPress.jitterFilter.tolerance) 逻辑点），进入拖动"
                : (!result.scroll.isEmpty ? "长按取消：已进入浏览滚动" : (events.contains { $0.action == .down } ? "长按结束：提前抬笔，转单击" : "长按取消：输入失效或离开范围")))
        }
        emit(events)
        emitScroll(result.scroll)
        if gesture.hasScheduledClick { scheduleLongPress() }
        else { longPressTimer?.invalidate(); longPressTimer = nil }
        if !contact { contactSample = nil }
        if tabletEnabled && (!sample.inRange || !sample.positionValid || sample.eraser) && inProximity {
            sendProximity(false, at: lastPoint)
        }
    }
    func release() {
        longPressTimer?.invalidate(); longPressTimer = nil
        let cancelled = gesture.cancelNavigation()
        emit(cancelled.pointer); emitScroll(cancelled.scroll)
        if let anchor = postedScrollAnchor { _ = sendScroll(PenScrollEvent(anchor: anchor, phase: .cancelled)) }
        if postedLeft { _ = send(.up, at: lastPoint) }
        if postedRight { _ = send(.rightUp, at: lastPoint) }
        if inProximity { sendProximity(false, at: lastPoint) }
        currentSample = nil; contactSample = nil
        clicks.reset()
    }
    private func emitScroll(_ events: [PenScrollEvent]) {
        for event in events {
            // A scroll sequence is never part of a later multiple-click sequence.
            clicks.reset()
            guard sendScroll(event) else {
                let cancelled = gesture.cancelNavigation()
                for end in cancelled.scroll { _ = sendScroll(end) }
                return
            }
        }
    }
    @discardableResult private func sendScroll(_ planned: PenScrollEvent) -> Bool {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                 wheel1: planned.vertical, wheel2: planned.horizontal, wheel3: 0) else { return false }
        event.location = planned.anchor
        lastWarpError = CGWarpMouseCursorPosition(planned.anchor)
        let ending = planned.phase == .ended || planned.phase == .cancelled
        guard lastWarpError == .success || ending else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: bridgeEventTag)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let phase: CGScrollPhase
        switch planned.phase {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.post(tap: .cghidEventTap); didPost()
        postedScrollAnchor = ending ? nil : planned.anchor
        scrollEventCount += 1
        if planned.phase == .began {
            scrollGestureCount += 1
            longPressDiagnostic("浏览滚动开始：固定落笔位置，纵向优先，无惯性")
        }
        if ending { longPressDiagnostic("浏览滚动结束：\(planned.phase == .cancelled ? "已取消" : "抬笔")；未补发单击") }
        lastPoint = planned.anchor
        return true
    }
    private func sendProximity(_ entering: Bool, at point: CGPoint) {
        guard let event = CGEvent(source: source) else { return }
        event.type = .tabletProximity; event.location = point
        event.setIntegerValueField(.eventSourceUserData, value: bridgeEventTag)
        event.setIntegerValueField(.tabletProximityEventVendorID, value: 0x2717)
        event.setIntegerValueField(.tabletProximityEventTabletID, value: 0x2d05)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: tabletID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: tabletID)
        event.setIntegerValueField(.tabletProximityEventPointerType, value: 1)
        // Public IOLLEvent.h masks: deviceID, absXY, tip button, tiltXY, pressure.
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x5c7)
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        event.post(tap: .cghidEventTap)
        inProximity = entering; proximityCount += 1
    }
    @discardableResult private func send(_ action: PointerAction, at point: CGPoint) -> Bool {
        let type: CGEventType
        switch action {
        case .move: type = .mouseMoved
        case .down: type = .leftMouseDown
        case .drag: type = .leftMouseDragged
        case .up: type = .leftMouseUp
        case .rightDown: type = .rightMouseDown
        case .rightUp: type = .rightMouseUp
        }
        let right = action == .rightDown || action == .rightUp
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: right ? .right : .left) else { return false }
        // Position in the global desktop first, including when the cursor starts on another display.
        // Warping does not itself generate a mouse event; the event below supplies that event.
        lastWarpError = CGWarpMouseCursorPosition(point)
        guard lastWarpError == .success || action == .up || action == .rightUp else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: bridgeEventTag)
        if action != .move { event.setIntegerValueField(.mouseEventClickState, value: right ? 1 : clickCount) }
        if tabletEnabled && contactMode == .pointer && !right {
            event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            event.setIntegerValueField(.tabletEventDeviceID, value: tabletID)
            let contact = action == .down || action == .drag
            let pressure = contact ? Double(contactSample?.pressure ?? currentSample?.pressure ?? 0) / 8191 : 0
            let tilt = mapping.tilt(x: currentSample?.tiltX ?? 0, y: currentSample?.tiltY ?? 0)
            event.setDoubleValueField(.mouseEventPressure, value: pressure)
            event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            event.setDoubleValueField(.tabletEventTiltX, value: tilt.x)
            event.setDoubleValueField(.tabletEventTiltY, value: tilt.y)
            // Coordinates here are tablet-space units, separate from the desktop cursor position.
            let normalized = Mapping(bounds: CGRect(x: 0, y: 0, width: 32768, height: 32768),
                                     rotation: mapping.rotation, flipX: mapping.flipX, flipY: mapping.flipY)
            let raw = currentSample.map { normalized.point(x: $0.x, y: $0.y) } ?? .zero
            if action != .up {
                lastTabletPoint = raw
            }
            event.setIntegerValueField(.tabletEventPointX, value: Int64(lastTabletPoint.x))
            event.setIntegerValueField(.tabletEventPointY, value: Int64(lastTabletPoint.y))
            // Virtual pen controls remain diagnostic-only, including barrel/eraser bits.
            event.setIntegerValueField(.tabletEventPointButtons, value: contact ? 1 : 0)
        }
        event.post(tap: .cghidEventTap)
        didPost()
        if action == .down { downCount += 1; postedLeft = true }
        if action == .up { upCount += 1; postedLeft = false }
        if right { rightEventCount += 1 }
        if action == .rightDown { postedRight = true }
        if action == .rightUp {
            postedRight = false; rightClickCount += 1; clicks.reset()
            longPressDiagnostic("长按右键已提交：\(candidateTarget.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? "未知")；目标软件响应待验证")
        }
        if action == .move { moveCount += 1 }
        if action == .drag { dragCount += 1 }
        lastPoint = point
        if action == .up { clicks.end(now: ProcessInfo.processInfo.systemUptime, interval: NSEvent.doubleClickInterval) }
        return true
    }
}
