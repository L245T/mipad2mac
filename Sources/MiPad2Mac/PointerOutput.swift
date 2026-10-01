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
    let applicationProfiles: PenApplicationPreferences
    let clickPreferences: ClickPreferences
    private var lastExternalApplication: NSRunningApplication?
    var selectedProfileID: String?
    private var selectedProfileName: String?
    private var contactMode = PenNavigationMode.pointer
    var scrollEventCount = 0
    var scrollGestureCount = 0
    private var postedScrollAnchor: CGPoint?
    private var fallbackContact = false
    private var fallbackWindow: ScrollWindow?
    private var nextWindowValidation: TimeInterval = 0
    private let diagnosticOwnWindow: Bool
    private let diagnosticHitUnavailable: () -> Bool
    private let diagnosticWindowUnavailable: () -> Bool
    let momentumPreferences: ScrollMomentumPreferences
    private var momentum = PenScrollMomentum()
    private var momentumTimer: Timer?
    private var scrollWindow: ScrollWindow?
    private var momentumWindow: ScrollWindow?
    var momentumActive: Bool { momentum.isCoasting }
    var momentumEnabled: Bool {
        get { momentumPreferences.enabled }
        set { release(); momentumPreferences.enabled = newValue }
    }

    var profileID: String? { (selectedProfileID ?? lastExternalApplication?.bundleIdentifier)?.lowercased() }
    var profileName: String { selectedProfileName ?? lastExternalApplication?.localizedName ?? "请先选择应用" }
    var profileExcluded: Bool { profileMode == .drawing }
    var profileMode: PenApplicationMode { applicationProfiles.mode(for: profileID) }
    /// The independent list never includes the foreground app or implicit built-in defaults.
    var configuredProfiles: [PenApplicationProfile] { applicationProfiles.configuredApplications }
    var profileApplications: [String: String] {
        var apps = applicationProfiles.applications
        if let id = profileID { apps[id] = profileName }
        return apps
    }
    func selectProfile(_ id: String) {
        let name = profileApplications[id] ?? id
        selectedProfileID = id
        selectedProfileName = name
    }
    func changeNavigation(_ mode: PenApplicationMode) {
        guard let id = profileID else { return }
        setApplicationProfileMode(mode, for: id, name: profileName)
    }
    @discardableResult func addApplicationProfile(bundleID: String, name: String) -> Bool {
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        release()
        return applicationProfiles.add(for: bundleID, name: name) != nil
    }
    /// A list row passes its own ID; it must not change the current-app/HID-menu selection.
    func setApplicationProfileMode(_ mode: PenApplicationMode, for bundleID: String, name: String) {
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        release()
        applicationProfiles.set(mode, for: bundleID, name: name)
        longPressDiagnostic("应用默认模式：\(name) → \(mode.title)；已结束当前接触")
    }
    func removeApplicationProfile(bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return }
        release()
        applicationProfiles.remove(for: id)
        if selectedProfileID?.lowercased() == id {
            selectedProfileID = nil; selectedProfileName = nil
        }
        longPressDiagnostic("已移除应用笔模式：\(id)；回到默认浏览，已结束当前接触")
    }
    func chooseNavigationApplication() {
        release()
        let panel = NSOpenPanel()
        panel.title = "选择应用笔设置"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        selectedProfileID = id
        selectedProfileName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        addApplicationProfile(bundleID: id, name: profileName)
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
    private var contactClickTolerance = 0.0
    var rightClickCount = 0
    var rightEventCount = 0

    init(defaults: UserDefaults = .standard, observeApplications: Bool = true,
         diagnosticOwnWindow: Bool = false,
         diagnosticHitUnavailable: @escaping () -> Bool = { false },
         diagnosticWindowUnavailable: @escaping () -> Bool = { false }) {
        // Only the explicit, isolated local-event diagnostic can scroll its own receiver window.
        self.diagnosticOwnWindow = diagnosticOwnWindow && !observeApplications
        self.diagnosticHitUnavailable = diagnosticOwnWindow && !observeApplications ? diagnosticHitUnavailable : { false }
        self.diagnosticWindowUnavailable = diagnosticOwnWindow && !observeApplications ? diagnosticWindowUnavailable : { false }
        momentumPreferences = ScrollMomentumPreferences(defaults: defaults)
        longPress = LongPressPreferences(defaults: defaults)
        navigation = PenNavigationPreferences(defaults: defaults)
        applicationProfiles = PenApplicationPreferences(defaults: defaults)
        clickPreferences = ClickPreferences(defaults: defaults)
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
        longPressTimer?.invalidate(); momentumTimer?.invalidate()
        if let applicationObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver) }
    }
    // AX hit testing identifies the application under the pen, including inactive windows.
    // Browse profiles use a guarded window fallback when region metadata is unavailable.
    private struct PenTarget {
        let app: NSRunningApplication?
        let region: PenHitRegion
        let nodes: [PenHitNode]
        let endReason: String
    }
    /// AppKit mouse-down hit testing skips transparent/ignoresMouseEvents overlays.
    private struct ScrollWindow {
        let id: CGWindowID
        let app: NSRunningApplication
        let bounds: CGRect
        let layer: Int
    }
    private func window(at point: CGPoint) -> ScrollWindow? {
        if diagnosticWindowUnavailable() { return nil }
        guard let top = NSScreen.screens.first?.frame.maxY else { return nil }
        let number = NSWindow.windowNumber(at: NSPoint(x: point.x, y: top - point.y), belowWindowWithWindowNumber: 0)
        guard number > 0, let id = CGWindowID(exactly: number),
              let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], id) as? [[String: Any]],
              let item = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              let data = item[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: data), bounds.contains(point),
              let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil else { return nil }
        return ScrollWindow(id: id, app: app, bounds: bounds,
                            layer: (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1)
    }
    private func target(at point: CGPoint) -> PenTarget? {
        if diagnosticHitUnavailable() { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
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
        var nodes: [PenHitNode] = []
        var ancestor = element
        var endReason = "层数上限"
        for _ in 0..<32 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { endReason = "查询超时"; break }
            AXUIElementSetMessagingTimeout(ancestor, Float(min(0.03, remaining)))
            var value: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(ancestor, kAXRoleAttribute as CFString, &value)
            guard roleResult == .success, let role = value as? String else {
                endReason = "角色查询失败(\(roleResult.rawValue))"; break
            }
            var editable: Bool?
            if role == kAXTextAreaRole || role == kAXTextFieldRole {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining > 0 {
                    AXUIElementSetMessagingTimeout(ancestor, Float(min(0.03, remaining)))
                    var settable: DarwinBoolean = false
                    if AXUIElementIsAttributeSettable(ancestor, kAXValueAttribute as CFString, &settable) == .success {
                        editable = settable.boolValue
                    }
                }
            }
            nodes.append(PenHitNode(role: role, valueEditable: editable))
            if role == kAXWindowRole { endReason = "到达窗口"; break }
            let parentRemaining = deadline - ProcessInfo.processInfo.systemUptime
            guard parentRemaining > 0 else { endReason = "查询超时"; break }
            AXUIElementSetMessagingTimeout(ancestor, Float(min(0.03, parentRemaining)))
            let parentResult = AXUIElementCopyAttributeValue(ancestor, kAXParentAttribute as CFString, &value)
            guard parentResult == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                endReason = "父级查询结束(\(parentResult.rawValue))"; break
            }
            ancestor = unsafeBitCast(value, to: AXUIElement.self)
        }
        return PenTarget(app: app, region: PenHitRegion.classify(nodes: nodes), nodes: nodes, endReason: endReason)
    }

    func changeLongPress(_ edit: (LongPressPreferences) -> Void) {
        release(); edit(longPress)
    }
    func changeClickTolerance(_ value: Double) {
        release(); clickPreferences.jitterTolerance = value
    }
    func addCompatibilityApplication() {
        release()
        let panel = NSOpenPanel()
        panel.title = "选择使用右键兼容模式的应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        changeLongPress { settings in
            var apps = settings.compatibilityApplications
            apps[id] = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            settings.compatibilityApplications = apps
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
                  (self.fallbackContact
                    ? self.validFallbackWindow(at: self.pressLocation)
                    : self.target(at: self.pressLocation)?.app?.processIdentifier == candidateTarget),
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
                clickCount = clicks.begin(at: planned.point, now: contactStarted, interval: NSEvent.doubleClickInterval,
                                          extraTolerance: contactClickTolerance)
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
        let now = ProcessInfo.processInfo.systemUptime
        currentSample = sample
        let contact = sample.touching && sample.inRange && !sample.eraser
        if contact && momentum.isCoasting { stopMomentum() }
        if gesture.isIdle && contact && sample.positionValid {
            stopMomentum()
            contactStarted = now
            pressLocation = mapping.point(x: sample.x, y: sample.y)
            let frontmost = NSWorkspace.shared.frontmostApplication
            // Default browse needs region/window lookup even with an empty saved-app list or long press off.
            let hit = target(at: pressLocation)
            let topWindow = window(at: pressLocation)
            let matchingHit = topWindow == nil || hit?.app?.processIdentifier == topWindow?.app.processIdentifier ? hit : nil
            let resolvedApp = topWindow?.app ?? matchingHit?.app
            let targetApp = matchingHit?.app
            let appMode = applicationProfiles.mode(for: resolvedApp?.bundleIdentifier ?? frontmost?.bundleIdentifier)
            let unknown = matchingHit?.region == nil || matchingHit?.region == .unknown
            contactMode = PenBrowseRouting.mode(applicationMode: appMode, region: matchingHit?.region ?? .unknown,
                point: pressLocation, windowBounds: topWindow?.bounds, windowLayer: topWindow?.layer,
                ownWindow: topWindow?.app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                allowOwnWindow: diagnosticOwnWindow)
            fallbackContact = contactMode == .browse && unknown
            fallbackWindow = fallbackContact ? topWindow : nil
            nextWindowValidation = 0
            if fallbackContact { longPressDiagnostic("未知区域持续浏览：\(resolvedApp?.bundleIdentifier ?? "未知")；窗口顶部保留拖动") }
            contactClickTolerance = appMode == .drawing ? 0 : clickPreferences.jitterTolerance
            candidateTarget = fallbackContact ? topWindow?.app.processIdentifier : targetApp?.processIdentifier
            candidateFrontmost = frontmost?.processIdentifier
            // Second/third held taps retain selection, including unknown custom content.
            let multiTapSelection = contactMode == .browse
                && clicks.nextCount(at: pressLocation, now: contactStarted, interval: NSEvent.doubleClickInterval,
                                   extraTolerance: contactClickTolerance) > 1
            if multiTapSelection { contactMode = .pointer }
            scrollWindow = contactMode == .browse ? topWindow : nil
            if appMode == .browse {
                let path = hit?.nodes.map { node in
                    node.role + (node.valueEditable.map { $0 ? "[可编辑]" : "[只读]" } ?? "")
                }.joined(separator: " → ") ?? "无区域信息"
                longPressDiagnostic("浏览区域判定：\(targetApp?.bundleIdentifier ?? "未知")；\(path)；\(hit?.endReason ?? "目标查询失败")；区域\(String(describing: hit?.region)) → \(contactMode.title)")
            }
            deferredContact = longPress.enabled && appMode != .drawing && matchingHit?.region != .chrome && (!unknown || fallbackContact) && (targetApp != nil || fallbackContact) && !multiTapSelection
            if multiTapSelection { longPressDiagnostic("连续点按：本次接触保持文字选择，不滚动、不触发长按右键") }
            compatibilityContact = deferredContact && longPress.compatibilityEnabled
                && (targetApp?.bundleIdentifier.map { id in
                    longPress.compatibilityApplications.keys.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
                } ?? false)
            if longPress.enabled {
                longPressDiagnostic("长按判定：目标 \(targetApp?.bundleIdentifier ?? "未知")，前台 \(frontmost?.bundleIdentifier ?? "未知")，\(deferredContact ? "开始计时" : "即时左键（排除或目标未识别）")")
            }
        }
        if !contact && gesture.isIdle {
            let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            contactMode = applicationProfiles.mode(for: id) == .browse ? .browse : .pointer
        }
        if contactMode == .browse && inProximity { sendProximity(false, at: lastPoint) }
        if tabletEnabled && contactMode == .pointer && sample.inRange && sample.positionValid && !sample.eraser && !inProximity {
            sendProximity(true, at: mapping.point(x: sample.x, y: sample.y))
        }
        if contact { contactSample = sample }
        // A deferred tap is emitted on lift; retain the last actual contact's tablet fields.
        if !contact && gesture.isPending { currentSample = contactSample }
        let wasPending = gesture.isPending
        let result = gesture.consumeNavigation(sample, mapping: mapping, now: now,
                                     enabled: deferredContact, delay: longPress.delay, drawing: tabletEnabled,
                                     jitterFilter: longPress.jitterFilter, navigation: contactMode)
        let events = result.pointer
        if wasPending && !gesture.isPending {
            longPressDiagnostic(events.contains { $0.action == .drag }
                ? "长按取消：移动超出抖动过滤范围（\(longPress.jitterFilter.title)，\(longPress.jitterFilter.tolerance) 逻辑点），进入拖动"
                : (!result.scroll.isEmpty ? "长按取消：已进入浏览滚动" : (events.contains { $0.action == .down } ? "长按结束：提前抬笔，转单击" : "长按取消：输入失效或离开范围")))
        }
        if let begin = result.scroll.first(where: { $0.phase == .began }) {
            momentum.start(anchor: begin.anchor, axis: begin.horizontal != 0 ? .horizontal : .vertical, now: contactStarted)
        }
        if contact && gesture.isScrolling && sample.positionValid {
            momentum.record(mapping.point(x: sample.x, y: sample.y), pressure: Double(sample.pressure) / 8191, now: now)
        }
        // Direct scrolling ends before the separate native momentum phase begins.
        emitScroll(result.scroll)
        if result.scroll.contains(where: { $0.phase == .ended }), sample.inRange, !sample.eraser {
            beginMomentum(now: now)
        }
        if result.scroll.contains(where: { $0.phase == .cancelled }) { stopMomentum() }
        emit(events)
        if gesture.hasScheduledClick { scheduleLongPress() }
        else { longPressTimer?.invalidate(); longPressTimer = nil }
        if !contact { contactSample = nil; fallbackContact = false; fallbackWindow = nil }
        if tabletEnabled && (!sample.inRange || !sample.positionValid || sample.eraser) && inProximity {
            sendProximity(false, at: lastPoint)
        }
    }
    func release() {
        stopMomentum()
        longPressTimer?.invalidate(); longPressTimer = nil
        let cancelled = gesture.cancelNavigation()
        emit(cancelled.pointer); emitScroll(cancelled.scroll)
        if let anchor = postedScrollAnchor { _ = sendScroll(PenScrollEvent(anchor: anchor, phase: .cancelled)) }
        if postedLeft { _ = send(.up, at: lastPoint) }
        if postedRight { _ = send(.rightUp, at: lastPoint) }
        if inProximity { sendProximity(false, at: lastPoint) }
        currentSample = nil; contactSample = nil
        clicks.reset()
        fallbackContact = false; fallbackWindow = nil; scrollWindow = nil
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
    private func validFallbackWindow(at point: CGPoint) -> Bool {
        guard let expected = fallbackWindow, let current = window(at: point) else { return false }
        return current.id == expected.id && current.app.processIdentifier == expected.app.processIdentifier
            && current.layer == 0 && current.bounds == expected.bounds
    }
    @discardableResult private func sendScroll(_ planned: PenScrollEvent) -> Bool {
        if fallbackContact {
            let now = ProcessInfo.processInfo.systemUptime
            if planned.phase != .changed || now >= nextWindowValidation {
                guard let expected = fallbackWindow, let current = window(at: planned.anchor),
                      current.id == expected.id, current.app.processIdentifier == expected.app.processIdentifier,
                      current.layer == 0, current.bounds == expected.bounds else {
                    postedScrollAnchor = nil
                    longPressDiagnostic("未知区域滚动已取消：目标窗口改变或被遮挡")
                    return false
                }
                nextWindowValidation = now + 0.05
            }
        }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                 wheel1: planned.vertical, wheel2: planned.horizontal, wheel3: 0) else { return false }
        event.location = planned.anchor
        let ending = planned.phase == .ended || planned.phase == .cancelled
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
            longPressDiagnostic("浏览滚动开始：固定内容目标，光标跟随笔尖，纵向优先")
        }
        if ending { longPressDiagnostic("浏览滚动结束：\(planned.phase == .cancelled ? "已取消" : "抬笔")；未补发单击") }
        return true
    }
    private func beginMomentum(now: Double) {
        guard let target = scrollWindow, target.layer == 0,
              momentum.lift(now: now, enabled: momentumEnabled) else { _ = momentum.cancel(); return }
        momentumWindow = target
        guard validMomentumWindow() else { stopMomentum(notifyTarget: false); return }
        longPressDiagnostic("惯性滚动开始：按速度与有限笔压调整，沿原内容位置减速")
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.validMomentumWindow() else {
                self.longPressDiagnostic("惯性滚动停止：目标窗口改变或被遮挡")
                self.stopMomentum(notifyTarget: false); return
            }
            if let event = self.momentum.tick(now: ProcessInfo.processInfo.systemUptime) {
                if !self.sendMomentum(event) { self.stopMomentum(notifyTarget: false); return }
            }
            if !self.momentum.isCoasting { self.momentumTimer?.invalidate(); self.momentumTimer = nil; self.momentumWindow = nil }
        }
        momentumTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func validMomentumWindow() -> Bool {
        guard let expected = momentumWindow, let current = window(at: pressLocation) else { return false }
        return current.id == expected.id && current.app.processIdentifier == expected.app.processIdentifier
            && current.layer == 0 && current.bounds == expected.bounds
    }
    private func stopMomentum(notifyTarget: Bool = true) {
        momentumTimer?.invalidate(); momentumTimer = nil
        if let end = momentum.cancel(), notifyTarget && validMomentumWindow() { _ = sendMomentum(end) }
        momentumWindow = nil
    }
    @discardableResult private func sendMomentum(_ planned: PenMomentumEvent) -> Bool {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: planned.vertical, wheel2: planned.horizontal, wheel3: 0) else { return false }
        // WindowServer may move the cursor to an injected scroll event's location.
        let liveCursor = CGEvent(source: nil)?.location ?? lastPoint
        event.location = planned.anchor
        let phase: CGMomentumScrollPhase
        switch planned.phase { case .began: phase = .begin; case .changed: phase = .continuous; case .ended: phase = .end }
        event.setIntegerValueField(.eventSourceUserData, value: bridgeEventTag)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(phase.rawValue))
        event.post(tap: .cghidEventTap); didPost(); scrollEventCount += 1
        // Restore the current position with a move only; never click or drag during a coast.
        return send(.move, at: liveCursor)
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
