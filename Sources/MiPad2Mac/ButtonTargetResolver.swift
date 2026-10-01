import AppKit
import ApplicationServices
import MiPadCore

/// Metadata-only, bounded AX enumeration. Partial trees never yield a nearest target.
final class ButtonTargetResolver {
    private(set) var validationFailure = ""
    struct Target {
        let element: AXUIElement
        let window: AXUIElement
        let windowID: CGWindowID
        let processID: pid_t
        let windowBounds: CGRect
        let bounds: CGRect
        let point: CGPoint
    }
    private struct Metadata {
        let role: String
        let subrole: String?
        let bounds: CGRect?
        let enabled: Bool?
        let hidden: Bool
    }
    private let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute,
                              kAXSizeAttribute, kAXEnabledAttribute, kAXHiddenAttribute] as CFArray
    private func prepare(_ element: AXUIElement, deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(min(0.008, remaining))) == .success
    }
    private func metadata(_ element: AXUIElement, deadline: TimeInterval) -> Metadata? {
        guard prepare(element, deadline: deadline) else { return nil }
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
              let entries = values as? [Any], entries.count == 6, let role = entries[0] as? String else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        var bounds: CGRect?
        let p = entries[2] as CFTypeRef, s = entries[3] as CFTypeRef
        if CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
           AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
           AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) {
            let frame = CGRect(origin: point, size: size)
            if ButtonTargetGeometry.valid(frame) { bounds = frame }
        }
        return Metadata(role: role, subrole: entries[1] as? String, bounds: bounds,
                        enabled: entries[4] as? Bool, hidden: entries[5] as? Bool == true)
    }
    private func children(_ element: AXUIElement, role: String, remaining: Int,
                          deadline: TimeInterval) -> [AXUIElement]? {
        guard prepare(element, deadline: deadline) else { return nil }
        var count: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        if result == .attributeUnsupported || result == .noValue {
            // Only known leaf roles may omit Children. Unknown containers fail closed.
            let leaves = [kAXButtonRole, kAXStaticTextRole, kAXImageRole, kAXTextFieldRole, kAXTextAreaRole,
                          kAXScrollBarRole, kAXSliderRole, kAXCheckBoxRole, kAXRadioButtonRole]
            return leaves.contains(role) ? [] : nil
        }
        guard result == .success, count >= 0, count <= remaining else { return nil }
        if count == 0 { return [] }
        guard prepare(element, deadline: deadline) else { return nil }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &values) == .success,
              let entries = values as? [Any], entries.count == count else { return nil }
        var children: [AXUIElement] = []
        for item in entries {
            let value = item as CFTypeRef
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            children.append(unsafeBitCast(value, to: AXUIElement.self))
        }
        return children
    }
    func resolve(point: CGPoint, radius: Double, window: AXUIElement, windowID: CGWindowID,
                 processID: pid_t, windowBounds: CGRect, deadline: TimeInterval) -> Target? {
        guard radius > 0, ButtonTargetGeometry.valid(windowBounds),
              windowBounds.contains(point), point.y >= windowBounds.minY + 32,
              let root = metadata(window, deadline: deadline), root.role == kAXWindowRole,
              root.bounds == windowBounds else { return nil }
        // Enumerate the whole bounded window: a container frame alone cannot prove clipping.
        // Large/custom/web trees fall back instead of presenting a sparse sample as nearest.
        var queue: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
        var visited: [AXUIElement] = []
        var candidates: [(AXUIElement, CGRect)] = []
        while !queue.isEmpty {
            let (element, depth, inheritedHidden) = queue.removeFirst()
            guard visited.count < 48, depth <= 6, !visited.contains(where: { CFEqual($0, element) }),
                  let data = metadata(element, deadline: deadline) else { return nil }
            visited.append(element)
            let hidden = inheritedHidden || data.hidden
            if data.role == kAXButtonRole {
                // Without geometry we cannot rule out a closer button, even if another was found.
                guard let frame = data.bounds, let enabled = data.enabled else { return nil }
                if !hidden, enabled, data.subrole == nil || data.subrole == kAXUnknownSubrole,
                   windowBounds.contains(frame), frame.minY >= windowBounds.minY + 32 {
                    candidates.append((element, frame))
                }
            }
            guard let descendants = children(element, role: data.role, remaining: 48 - visited.count - queue.count,
                                             deadline: deadline) else { return nil }
            queue.append(contentsOf: descendants.map { ($0, depth + 1, hidden) })
        }
        guard ProcessInfo.processInfo.systemUptime < deadline,
              let index = ButtonTargetGeometry.nearest(to: point, radius: radius,
                                                        frames: candidates.map { $0.1 }, complete: true) else { return nil }
        let candidate = candidates[index]
        return Target(element: candidate.0, window: window, windowID: windowID, processID: processID,
                      windowBounds: windowBounds, bounds: candidate.1,
                      point: ButtonTargetGeometry.clickPoint(from: point, inside: candidate.1))
    }
    func validatedPoint(_ target: Target, deadline: TimeInterval) -> CGPoint? {
        validationFailure = "按钮或窗口元数据改变／超时"
        var pid: pid_t = 0
        guard AXUIElementGetPid(target.element, &pid) == .success, pid == target.processID,
              let data = metadata(target.element, deadline: deadline), data.role == kAXButtonRole,
              data.enabled == true, !data.hidden, data.bounds == target.bounds,
              let root = metadata(target.window, deadline: deadline), root.bounds == target.windowBounds else { return nil }
        let system = AXUIElementCreateSystemWide()
        validationFailure = "辅助位置未命中原按钮"
        // AX frames can include non-clickable bezel/focus padding. These are checks inside the
        // already selected nearest button, not sparse sampling to discover a different target.
        let frame = target.bounds
        let dx = min(3, frame.width / 2), dy = min(3, frame.height / 2)
        let inset = CGPoint(x: min(frame.maxX - dx, max(frame.minX + dx, target.point.x)),
                            y: min(frame.maxY - dy, max(frame.minY + dy, target.point.y)))
        let points = [target.point, inset, CGPoint(x: frame.midX, y: frame.midY)]
        for point in points {
            guard prepare(system, deadline: deadline) else { return nil }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  var current = hit else { return nil }
            for _ in 0..<6 {
                if CFEqual(current, target.element) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { validationFailure = "最终命中超时"; return nil }
                    validationFailure = ""; return point
                }
                if CFEqual(current, target.window) { break }
                guard prepare(current, deadline: deadline) else { return nil }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                current = unsafeBitCast(parent, to: AXUIElement.self)
            }
        }
        return nil
    }
}
