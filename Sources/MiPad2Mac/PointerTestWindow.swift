import AppKit

let bridgeEventTag: Int64 = 0x4d4950414432

/// Receives normal macOS events so a posted HID conversion is not mistaken for a delivered click.
final class PointerTestView: NSView {
    var record: (String) -> Void = { _ in }
    var bridgeDown = 0
    var bridgeUp = 0
    var bridgeClicks = 0
    var systemDown = 0
    var cursor = CGPoint.zero
    var lastMessage = "请用笔轻点中央及四角，再拖动。此页区分桥接事件与系统原生事件。"
    private var downPoint: CGPoint?
    private var dragged = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == bridgeEventTag {
            bridgeDown += 1; downPoint = cursor; dragged = false
            lastMessage = "收到 MiPad2Mac 按下，等待抬起"
        } else {
            systemDown += 1; downPoint = nil
            lastMessage = "收到系统/其他来源的鼠标按下（不是 MiPad2Mac 标记事件）"
        }
        record(lastMessage)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if let downPoint, hypot(cursor.x - downPoint.x, cursor.y - downPoint.y) >= 4 { dragged = true }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == bridgeEventTag {
            bridgeUp += 1
            if let downPoint, !dragged, hypot(cursor.x - downPoint.x, cursor.y - downPoint.y) < 4 {
                bridgeClicks += 1
                lastMessage = "完整轻点已到达此窗口；系统 clickCount = \(event.clickCount)"
            } else { lastMessage = "收到桥接抬起（拖动或本窗口未收到对应按下）" }
            downPoint = nil
            record("\(lastMessage) · 累计按下 \(bridgeDown) / 抬起 \(bridgeUp) / 轻点 \(bridgeClicks)")
        }
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let title = "MiPad2Mac 输入验收"
        title.draw(at: NSPoint(x: 24, y: bounds.height - 55), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.labelColor])
        let detail = "桥接按下 \(bridgeDown) / 抬起 \(bridgeUp) / 完整轻点 \(bridgeClicks)　·　其他来源按下 \(systemDown)\n\(lastMessage)"
        detail.draw(in: NSRect(x: 24, y: bounds.height - 125, width: bounds.width - 48, height: 62), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor])
        for (u, v) in [(0.12, 0.18), (0.88, 0.18), (0.5, 0.45), (0.12, 0.72), (0.88, 0.72)] {
            let p = CGPoint(x: bounds.width * u, y: bounds.height * v)
            NSColor.systemBlue.setStroke()
            let circle = NSBezierPath(ovalIn: NSRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44))
            circle.lineWidth = 2; circle.stroke()
        }
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: cursor.x - 5, y: cursor.y - 5, width: 10, height: 10)).fill()
    }
}
