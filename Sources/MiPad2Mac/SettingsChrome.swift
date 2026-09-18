import AppKit
import SwiftUI
import MiPadCore

/// Lighten only the material mask; labels and controls retain full opacity.
/// Public AppKit materials do not expose a configurable blur radius.
final class SettingsMaterialView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateCoverage), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateCoverage()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func updateCoverage() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
            maskImage = nil
            return
        }
        maskImage = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
            NSColor.white.withAlphaComponent(0.88).setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
}

/// Scroll content behind a native frosted titlebar, with a matching initial inset.
final class SettingsContentController: NSViewController {
    let host: NSHostingController<SettingsDetail>
    let heading = NSTextField(labelWithString: "控制")
    private let header = NSView()
    private let model: SettingsPresentation
    init(model: SettingsPresentation) { self.model = model; host = NSHostingController(rootView: SettingsDetail(model: model)); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.clipsToBounds = true
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        addChild(host); host.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
    }
    func install(in window: NSWindow) {
        guard let guide = window.contentLayoutGuide as? NSLayoutGuide else { return }
        host.view.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        header.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(header)
        let titleContent = NSView()
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            glass.contentView = titleContent
            surface = glass
        } else {
            let material = SettingsMaterialView()
            material.material = .titlebar
            material.blendingMode = .withinWindow
            material.state = .followsWindowActiveState
            titleContent.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(titleContent)
            NSLayoutConstraint.activate([
                titleContent.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                titleContent.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                titleContent.topAnchor.constraint(equalTo: material.topAnchor),
                titleContent.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ])
            surface = material
        }
        surface.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            surface.topAnchor.constraint(equalTo: header.topAnchor),
            surface.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])
        heading.font = .systemFont(ofSize: 17, weight: .bold)
        heading.translatesAutoresizingMaskIntoConstraints = false; titleContent.addSubview(heading)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor), header.bottomAnchor.constraint(equalTo: guide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 30),
            heading.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -20)
        ])
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let height = header.bounds.height
        if abs(model.contentTopInset - height) > 0.5 { model.contentTopInset = height }
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
        table.headerView = nil; table.style = .sourceList; table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.rowHeight = 32; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsEmptySelection = false; table.dataSource = self; table.delegate = self
        scroll.documentView = table
        view = NSView(); view.clipsToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        table.selectRowIndexes(IndexSet(integer: model.selection), byExtendingSelection: false)
    }
    func install(in window: NSWindow) {
        guard let guide = window.contentLayoutGuide as? NSLayoutGuide else { return }
        scroll.topAnchor.constraint(equalTo: guide.topAnchor).isActive = true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { SystemSettingsController.names.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: SystemSettingsController.names[row]); label.font = .systemFont(ofSize: 13)
        let image = NSImageView(); image.image = NSImage(systemSymbolName: ["pencil", "checkmark.shield", "waveform.path", "gearshape", "info.circle"][row], accessibilityDescription: nil)
        image.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        cell.textField = label; cell.imageView = image
        for child in [label, image] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor), image.widthAnchor.constraint(equalToConstant: 22), image.heightAnchor.constraint(equalToConstant: 22), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 { model.app.tabs?.selectTabViewItem(at: table.selectedRow) }
    }
    func select(_ index: Int) {
        if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }
}
/// Standard SwiftUI switch supplies native tracking, focus and accessibility labels.
struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            VStack(alignment: .leading, spacing: 3) { configuration.label }
                .font(.body).frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.mini)
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
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(calibratedWhite: dark ? 0.16 : 0.90, alpha: 1).setFill()
        bounds.fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Preserve AppKit tracking and overlay behavior; customize only the always-visible rail.
final class SettingsScroller: NSScroller {
    weak var ownerScroll: NSScrollView?
    var titlebarInset: CGFloat = 0 {
        didSet { if titlebarInset != oldValue { frame = frame } }
    }
    override var frame: NSRect {
        get { super.frame }
        set {
            var adjusted = newValue
            if titlebarInset > 0, scrollerStyle == .legacy, let scroll = ownerScroll {
                let clip = scroll.contentView.frame
                adjusted.origin.y = clip.minY + (scroll.isFlipped ? titlebarInset : 0)
                adjusted.size.height = max(0, clip.height - titlebarInset)
            }
            super.frame = adjusted
        }
    }
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
    var extendsUnderTitlebar = false
    var topInset: CGFloat = 0
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.extendsUnderTitlebar = extendsUnderTitlebar; view.topInset = topInset; view.installWhenAttached() }
    final class Marker: NSView {
        var extendsUnderTitlebar = false
        var topInset: CGFloat = 0
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installWhenAttached() }
        func installWhenAttached() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                if self.extendsUnderTitlebar {
                    scroll.automaticallyAdjustsContentInsets = false
                    scroll.contentInsets = NSEdgeInsetsZero
                    scroll.scrollerInsets = NSEdgeInsets(top: self.topInset, left: 0, bottom: 0, right: 0)
                }
                if let existing = scroll.verticalScroller as? SettingsScroller {
                    existing.ownerScroll = scroll
                    existing.titlebarInset = self.extendsUnderTitlebar ? self.topInset : 0
                    return
                }
                guard let original = scroll.verticalScroller else { return }
                let replacement = SettingsScroller(frame: original.frame)
                replacement.controlSize = original.controlSize
                replacement.knobStyle = original.knobStyle
                replacement.target = original.target; replacement.action = original.action
                replacement.doubleValue = original.doubleValue
                replacement.knobProportion = original.knobProportion
                replacement.isEnabled = original.isEnabled
                scroll.verticalScroller = replacement
                replacement.ownerScroll = scroll
                replacement.titlebarInset = self.extendsUnderTitlebar ? self.topInset : 0
            }
        }
    }
}

/// Let SwiftUI own native tracking, integer stepping, geometry and Liquid Glass feedback.
struct SettingsIntegerSlider: View {
    @Binding var value: Double
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { value }, set: { value = min(18, max(0, $0.rounded())) }), in: 0...18) { Text("长按防抖") }
                .accessibilityAdjustableAction { direction in
                    guard isEnabled else { return }
                    switch direction {
                    case .increment: value = min(18, value + 1)
                    case .decrement: value = max(0, value - 1)
                    @unknown default: break
                    }
                }
                .onMoveCommand { direction in
                    guard isEnabled else { return }
                    switch direction {
                    case .right, .up: value = min(18, value + 1)
                    case .left, .down: value = max(0, value - 1)
                    default: break
                    }
                }
            tickLabels.frame(height: 16)
        }
        .labelsHidden()
        .controlSize(.regular)
        .accessibilityValue("\(Int(value))，范围0到18")
    }
    private var tickLabels: some View {
        GeometryReader { geometry in
            ForEach(0...18, id: \.self) { index in
                Group {
                    if let landmark = LongPressJitterFilter.landmarks.first(where: { $0.tolerance == Double(index) }) {
                        Text(landmark.title).font(.caption).fixedSize()
                    } else {
                        Circle().frame(width: 2, height: 2)
                    }
                }.foregroundStyle(.secondary)
                    .position(x: 10 + (geometry.size.width - 20) * Double(index) / 18,
                              y: 8)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
