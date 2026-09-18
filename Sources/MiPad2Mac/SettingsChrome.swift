import AppKit
import SwiftUI

/// Keep scrolling content entirely below the system title/toolbar, even at its top edge.
final class SettingsContentController: NSViewController {
    let host: NSHostingController<SettingsDetail>
    let heading = NSTextField(labelWithString: "控制")
    init(model: SettingsPresentation) { host = NSHostingController(rootView: SettingsDetail(model: model)); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView(); view.clipsToBounds = true
        addChild(host); host.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
    }
    func install(in window: NSWindow) {
        guard let guide = window.contentLayoutGuide as? NSLayoutGuide else { return }
        host.view.topAnchor.constraint(equalTo: guide.topAnchor).isActive = true
        let header = NSView(); header.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(header)
        heading.font = .systemFont(ofSize: 17, weight: .bold)
        heading.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(heading)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor), header.bottomAnchor.constraint(equalTo: guide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 30),
            heading.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -20)
        ])
    }
}

/// AppKit supplies keyboard selection, accessibility and SF Symbol rendering.
final class SettingsNavigation: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: SettingsPresentation
    let table = NSTableView()
    private let scroll = NSScrollView()
    init(model: SettingsPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.verticalScroller = SettingsScroller()
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page")))
        table.headerView = nil; table.style = .plain; table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.rowHeight = 32; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsEmptySelection = false; table.dataSource = self; table.delegate = self
        scroll.documentView = table
        view = NSView(); view.clipsToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        table.selectRowIndexes(IndexSet(integer: model.selection), byExtendingSelection: false)
    }
    func install(in window: NSWindow) {
        guard let guide = window.contentLayoutGuide as? NSLayoutGuide else { return }
        scroll.topAnchor.constraint(equalTo: guide.topAnchor).isActive = true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { SystemSettingsController.names.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SettingsSelectionRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: SystemSettingsController.names[row]); label.font = .systemFont(ofSize: 13)
        let image = NSImageView(); image.image = NSImage(systemSymbolName: ["pencil", "checkmark.shield", "waveform.path", "gearshape", "info.circle"][row], accessibilityDescription: nil)
        image.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        cell.textField = label; cell.imageView = image
        for child in [label, image] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), image.widthAnchor.constraint(equalToConstant: 22), image.heightAnchor.constraint(equalToConstant: 22), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 { model.app.tabs?.selectTabViewItem(at: table.selectedRow) }
    }
    func select(_ index: Int) {
        if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }
}
private final class SettingsSelectionRow: NSTableRowView {
    override var allowsVibrancy: Bool { false }
    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 9, yRadius: 9).fill()
    }
}

/// Native switch geometry and accessibility; do not scale a painted imitation.
private struct SettingsSwitch: NSViewRepresentable {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch(); control.controlSize = .mini
        control.target = context.coordinator; control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSSwitch, context: Context) {
        context.coordinator.parent = self
        let next: NSControl.StateValue = isOn ? .on : .off
        // Avoid resetting the native tracking animation during unrelated SwiftUI refreshes.
        if control.state != next { control.state = next }
        control.isEnabled = isEnabled
    }
    final class Coordinator: NSObject {
        var parent: SettingsSwitch
        init(_ parent: SettingsSwitch) { self.parent = parent }
        @objc func changed(_ sender: NSSwitch) { parent.isOn = sender.state == .on }
    }
}
struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) { configuration.label }.frame(maxWidth: .infinity, alignment: .leading)
            SettingsSwitch(isOn: configuration.$isOn).controlSize(.mini).fixedSize()
        }.accessibilityElement(children: .combine)
    }
}

/// Screenshot-calibrated grouping; these radii are project choices, not published HIG constants.
struct SettingsSection<Content: View, Header: View, Footer: View>: View {
    let content: Content; let header: Header; let footer: Footer
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if Header.self != EmptyView.self { header.font(.headline).padding(.horizontal, 10).padding(.top, 6) }
            VStack(spacing: 0) {
                if #available(macOS 15, *) {
                Group(subviews: content) { rows in
                    ForEach(rows.indices, id: \.self) { index in
                        if index != rows.startIndex { Divider().padding(.horizontal, 10) }
                        rows[index].frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 9)
                    }
                }
                } else { content.padding(10) }
            }.background(Color(nsColor: Self.fill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if Footer.self != EmptyView.self { footer.font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 10) }
        }
    }
    private static var fill: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            return NSColor(white: dark ? (increased ? 0.24 : 0.18) : (increased ? 0.92 : 0.965), alpha: 1)
        }
    }
}
extension SettingsSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { self.init(content: content, header: { EmptyView() }, footer: { EmptyView() }) }
}
extension SettingsSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(content: content, header: { Text(title) }, footer: { EmptyView() }) }
}
extension SettingsSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) { self.init(content: content, header: { EmptyView() }, footer: footer) }
}

struct SettingsValueStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label.layoutPriority(1)
            Spacer(minLength: 8)
            configuration.content.multilineTextAlignment(.trailing)
        }
    }
}
struct SettingsPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    let content: Content
    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        self.title = title; self._selection = selection; self.content = content()
    }
    var body: some View {
        LabeledContent(title) {
            Picker(title, selection: $selection) { content }.labelsHidden()
                .pickerStyle(.menu).buttonStyle(.borderless).fixedSize()
        }
    }
}

/// An AppKit background covers the titlebar region too; no SwiftUI safe-area inset.
final class OpaqueSidebarBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Preserve AppKit tracking and overlay behavior; customize only the always-visible rail.
final class SettingsScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard scrollerStyle == .legacy else { super.draw(dirtyRect); return }
        drawKnobSlot(in: rect(for: .knobSlot), highlight: false)
        super.drawKnob()
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard scrollerStyle == .legacy else { super.drawKnobSlot(in: slotRect, highlight: flag); return }
        let rail = rect(for: .knobSlot).insetBy(dx: 2, dy: 1)
        guard rail.width > 0, rail.height > 0 else { return }
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        (increased ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: rail, xRadius: rail.width / 2, yRadius: rail.width / 2).fill()
    }
}

/// Resolve the enclosing public NSScrollView from a marker inside SwiftUI scroll content.
/// No private class names, method swizzling or periodic hierarchy scans.
struct SettingsScrollTrack: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.installWhenAttached() }
    final class Marker: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installWhenAttached() }
        func installWhenAttached() {
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView,
                      let original = scroll.verticalScroller,
                      !(original is SettingsScroller) else { return }
                let replacement = SettingsScroller(frame: original.frame)
                replacement.controlSize = original.controlSize
                replacement.knobStyle = original.knobStyle
                replacement.target = original.target; replacement.action = original.action
                replacement.doubleValue = original.doubleValue
                replacement.knobProportion = original.knobProportion
                replacement.isEnabled = original.isEnabled
                scroll.verticalScroller = replacement
            }
        }
    }
}

/// Let SwiftUI own native tracking, integer stepping, geometry and Liquid Glass feedback.
struct SettingsIntegerSlider: View {
    @Binding var value: Double
    var body: some View {
        Slider(value: $value, in: 0...18, step: 1) { Text("长按防抖") }
            .labelsHidden()
            .controlSize(.regular)
            .accessibilityValue("\(Int(value))，范围0到18")
    }
}
