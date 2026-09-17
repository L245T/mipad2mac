import AppKit
import ApplicationServices
import MiPadCore

final class PointerOutput {
    // Experimental event-stream identity only; this does not register an OS tablet driver.
    // Keep IDs consistent between proximity and pointer events; never impersonate Wacom.
    let tabletID: Int64 = 0x4d49
    var tabletEnabled = false
    private var inProximity = false
    private var currentSample: Sample?
    var proximityCount = 0
    var didPost: () -> Void = {}
    var gesture = PointerGesture()
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
        if let planned = gesture.consume(sample, mapping: mapping, drawing: tabletEnabled) {
            let action = planned.action
            let point = planned.point
            if action == .down {
                let nearby = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) < 5
                clickCount = nearby && ProcessInfo.processInfo.systemUptime - lastRelease < NSEvent.doubleClickInterval ? min(clickCount + 1, 3) : 1
                lastClickPoint = point
            }
            send(action, at: point)
        }
        if tabletEnabled && (!sample.inRange || !sample.positionValid || sample.eraser) && inProximity {
            sendProximity(false, at: lastPoint)
        }
    }
    func release() {
        if let planned = gesture.release() { send(planned.action, at: planned.point) }
        if inProximity { sendProximity(false, at: lastPoint) }
        currentSample = nil
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
    private func send(_ action: PointerAction, at point: CGPoint) {
        let type: CGEventType
        switch action {
        case .move: type = .mouseMoved
        case .down: type = .leftMouseDown
        case .drag: type = .leftMouseDragged
        case .up: type = .leftMouseUp
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        // Position in the global desktop first, including when the cursor starts on another display.
        // Warping does not itself generate a mouse event; the event below supplies that event.
        lastWarpError = CGWarpMouseCursorPosition(point)
        guard lastWarpError == .success || action == .up else { return }
        event.setIntegerValueField(.eventSourceUserData, value: bridgeEventTag)
        if action != .move { event.setIntegerValueField(.mouseEventClickState, value: clickCount) }
        if tabletEnabled {
            event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            event.setIntegerValueField(.tabletEventDeviceID, value: tabletID)
            let contact = action == .down || action == .drag
            let pressure = contact ? Double(currentSample?.pressure ?? 0) / 8191 : 0
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
        if action == .down { downCount += 1 }
        if action == .up { upCount += 1 }
        if action == .move { moveCount += 1 }
        if action == .drag { dragCount += 1 }
        lastPoint = point
        if action == .up { lastRelease = ProcessInfo.processInfo.systemUptime }
    }
}
