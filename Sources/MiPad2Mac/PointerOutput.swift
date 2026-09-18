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
    let longPress = LongPressPreferences()
    private var longPressTimer: Timer?
    private var applicationObserver: NSObjectProtocol?
    private var candidateTarget: pid_t?
    private var candidateFrontmost: pid_t?
    private var contactSample: Sample?
    private var deferredContact = false
    private var pressLocation = CGPoint.zero
    private var postedLeft = false
    private var postedRight = false
    var rightClickCount = 0
    var rightEventCount = 0

    init() {
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.gesture.isPending else { return }
            self.longPressDiagnostic("长按取消：前台应用切换")
            self.release()
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
    func addExcludedApplication() {
        release()
        let panel = NSOpenPanel()
        panel.title = "选择不使用长按右键的绘画应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        changeLongPress { settings in
            var apps = settings.exclusions
            apps[id] = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            settings.exclusions = apps
        }
    }
    func resetConnection() { release(); gesture.reset() }
    private func scheduleLongPress() {
        guard longPressTimer == nil, let deadline = gesture.deadline else { return }
        let timer = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.longPressTimer = nil
            guard self.gesture.isPending else { return }
            guard let candidateTarget = self.candidateTarget,
                  self.target(at: self.pressLocation)?.processIdentifier == candidateTarget,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == self.candidateFrontmost else {
                self.longPressDiagnostic("长按取消：到时目标应用或前台应用已变化/无法识别")
                self.release(); return
            }
            self.emit(self.gesture.fire(now: ProcessInfo.processInfo.systemUptime))
            if self.gesture.isPending { self.scheduleLongPress() }
        }
        longPressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func emit(_ events: [PointerEvent]) {
        for planned in events {
            if planned.action == .down {
                let nearby = hypot(planned.point.x - lastClickPoint.x, planned.point.y - lastClickPoint.y) < 5
                clickCount = nearby && ProcessInfo.processInfo.systemUptime - lastRelease < NSEvent.doubleClickInterval ? min(clickCount + 1, 3) : 1
                lastClickPoint = planned.point
            }
            if !send(planned.action, at: planned.point) {
                // Release only buttons we actually submitted and suppress this contact after a failed post setup.
                _ = gesture.cancel()
                if postedLeft { _ = send(.up, at: lastPoint) }
                if postedRight { _ = send(.rightUp, at: lastPoint) }
                break
            }
        }
    }
    var lastPoint = CGPoint.zero
    private var lastTabletPoint = CGPoint.zero
    var mapping = Mapping(bounds: .zero)
    var lastRelease = -Double.infinity
    var lastClickPoint = CGPoint.zero
    var clickCount: Int64 = 1
    var downCount = 0
    var upCount = 0
    var moveCount = 0
    var dragCount = 0
    var lastWarpError: CGError = .success
    let source = CGEventSource(stateID: .privateState)
    func receive(_ sample: Sample) {
        currentSample = sample
        if tabletEnabled && sample.inRange && sample.positionValid && !sample.eraser && !inProximity {
            sendProximity(true, at: mapping.point(x: sample.x, y: sample.y))
        }
        let contact = sample.touching && sample.inRange && !sample.eraser
        if gesture.isIdle && contact && sample.positionValid {
            pressLocation = mapping.point(x: sample.x, y: sample.y)
            let frontmost = NSWorkspace.shared.frontmostApplication
            let frontmostExcluded = frontmost?.bundleIdentifier.map { longPress.excludes($0) } ?? false
            let targetApp = longPress.enabled && !frontmostExcluded ? target(at: pressLocation) : nil
            candidateTarget = targetApp?.processIdentifier
            candidateFrontmost = frontmost?.processIdentifier
            deferredContact = longPress.enabled && !frontmostExcluded
                && (targetApp?.bundleIdentifier.map { !longPress.excludes($0) } ?? false)
            if longPress.enabled {
                longPressDiagnostic("长按判定：目标 \(targetApp?.bundleIdentifier ?? "未知")，前台 \(frontmost?.bundleIdentifier ?? "未知")，\(deferredContact ? "开始计时" : "即时左键（排除或目标未识别）")")
            }
        }
        if contact { contactSample = sample }
        // A deferred tap is emitted on lift; retain the last actual contact's tablet fields.
        if !contact && gesture.isPending { currentSample = contactSample }
        let wasPending = gesture.isPending
        let events = gesture.consume(sample, mapping: mapping, now: ProcessInfo.processInfo.systemUptime,
                                     enabled: deferredContact, delay: longPress.delay, drawing: tabletEnabled)
        if wasPending && !gesture.isPending {
            longPressDiagnostic(events.contains { $0.action == .drag }
                ? "长按取消：移动达到 4 逻辑点，进入拖动"
                : (events.contains { $0.action == .down } ? "长按结束：提前抬笔，转单击" : "长按取消：输入失效或离开范围"))
        }
        emit(events)
        if gesture.isPending { scheduleLongPress() }
        else { longPressTimer?.invalidate(); longPressTimer = nil }
        if !contact { contactSample = nil }
        if tabletEnabled && (!sample.inRange || !sample.positionValid || sample.eraser) && inProximity {
            sendProximity(false, at: lastPoint)
        }
    }
    func release() {
        longPressTimer?.invalidate(); longPressTimer = nil
        emit(gesture.cancel())
        if postedLeft { _ = send(.up, at: lastPoint) }
        if postedRight { _ = send(.rightUp, at: lastPoint) }
        if inProximity { sendProximity(false, at: lastPoint) }
        currentSample = nil; contactSample = nil
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
        if tabletEnabled && !right {
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
            postedRight = false; rightClickCount += 1; lastRelease = -Double.infinity
            longPressDiagnostic("长按右键已提交：\(candidateTarget.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? "未知")；目标软件响应待验证")
        }
        if action == .move { moveCount += 1 }
        if action == .drag { dragCount += 1 }
        lastPoint = point
        if action == .up { lastRelease = ProcessInfo.processInfo.systemUptime }
        return true
    }
}
