import AppKit

/// Bounded, local-only test notes. Never captures keyboard input or the USB bus.
final class TestRecord {
    var enabled = false
    let view = NSScrollView()
    private let text = NSTextView()
    var displayText: String { lines.joined(separator: "\n") }
    private var lines: [String] = []
    private let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    init() {
        view.hasVerticalScroller = true
        view.borderType = .noBorder
        view.scrollerStyle = .overlay; view.autohidesScrollers = true
        view.heightAnchor.constraint(equalToConstant: 180).isActive = true
        text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        view.documentView = text
    }
    func append(_ message: String) {
        guard enabled else { return }
        lines.append("[\(clock.string(from: Date()))] \(message)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        text.string = lines.joined(separator: "\n")
        text.scrollToEndOfDocument(nil)
    }
    func clear() { lines.removeAll(); text.string = "" }
    func save(in window: NSWindow, extra: String = "") {
        let panel = NSSavePanel(); panel.title = "导出测试记录"; panel.prompt = "导出"
        panel.nameFieldLabel = "文件名称："; panel.nameFieldStringValue = "MiPad2Mac-test.txt"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let content = "MiPad2Mac \(appVersion) · 提交 \(appGitRevision.isEmpty ? "未关联" : appGitRevision) · 内容校验 \(appSourceRevision) · 测试记录\n" + lines.joined(separator: "\n") + "\n" + extra
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try content.write(to: url, atomically: true, encoding: .utf8) }
            catch {
                let alert = NSAlert(error: error); alert.beginSheetModal(for: window)
            }
        }
    }
}
