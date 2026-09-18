import AppKit

// Generate a self-contained 2x background; icon positions are defined in dmg-settings.py.
let width = 660, height = 440
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
func text(_ value: String, y: CGFloat, size: CGFloat, color: NSColor, bold: Bool = false) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    (value as NSString).draw(in: NSRect(x: 24, y: CGFloat(height) - y - size * 1.5, width: 612, height: size * 1.6),
        withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                         .foregroundColor: color, .paragraphStyle: style])
}
text("安装 MiPad2Mac", y: 38, size: 27, color: NSColor(calibratedWhite: 0.16, alpha: 1), bold: true)
text("将 MiPad2Mac 拖到右侧「应用程序」文件夹", y: 84, size: 16, color: NSColor(calibratedWhite: 0.36, alpha: 1))
let orange = NSColor(calibratedRed: 0.94, green: 0.43, blue: 0.14, alpha: 1)
orange.setStroke()
let arrow = NSBezierPath(); arrow.lineWidth = 4; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
let arrowY = CGFloat(height - 204)
arrow.move(to: NSPoint(x: 285, y: arrowY)); arrow.line(to: NSPoint(x: 375, y: arrowY))
arrow.move(to: NSPoint(x: 359, y: arrowY + 14)); arrow.line(to: NSPoint(x: 375, y: arrowY)); arrow.line(to: NSPoint(x: 359, y: arrowY - 14)); arrow.stroke()
text("安装完成后，推出磁盘映像，从应用程序文件夹启动", y: 395, size: 13, color: NSColor(calibratedWhite: 0.42, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
