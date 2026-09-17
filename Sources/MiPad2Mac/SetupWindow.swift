import AppKit

/// Standard AppKit controls with wrapping text and a scrollable document for small displays.
enum NativeLayout {
    final class Document: NSView { override var isFlipped: Bool { true } }
    static func text(_ string: String, heading: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = heading ? .boldSystemFont(ofSize: 16) : .systemFont(ofSize: 13)
        label.isSelectable = true
        return label
    }
    static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.spacing = 12; row.alignment = .centerY
        return row
    }
    static func heading(_ title: String, help: String) -> NSStackView {
        row([text(title, heading: true), HelpButton(title: title, explanation: help)])
    }
    static func card(_ views: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .custom; box.titlePosition = .noTitle
        box.cornerRadius = 10; box.borderWidth = 1
        box.borderColor = .separatorColor; box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 16, height: 14)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        let content = NSView()
        box.contentView = content
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            box.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 28)
        ])
        for view in views where view is NSTextField {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return box
    }
    static func page(_ views: [NSView]) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let doc = Document(); doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; doc.addSubview(stack)
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24)
        ])
        for view in views where view is NSTextField || view is NSPopUpButton || view is NSScrollView || view is NSBox || view is NativeToggle {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return scroll
    }
    static func tabs(_ pages: [(String, NSView)]) -> NSTabView {
        let tabs = NSTabView(); tabs.translatesAutoresizingMaskIntoConstraints = false
        for (name, view) in pages {
            let item = NSTabViewItem(identifier: name); item.label = name; item.view = view; tabs.addTabViewItem(item)
        }
        return tabs
    }
    static func install(_ view: NSView, in window: NSWindow) {
        let root = window.contentView!
        view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), view.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)])
    }
}

final class PermissionPage {
    let controlStatus = NativeLayout.text("")
    let inputStatus = NativeLayout.text("")
    let controlButton: NSButton
    let inputButton: NSButton
    let view: NSView
    init(owner: AppDelegate) {
        controlButton = NSButton(title: "申请控制权限…", target: owner, action: #selector(AppDelegate.requestPermissions))
        inputButton = NSButton(title: "申请输入监控权限…", target: owner, action: #selector(AppDelegate.requestInputPermission))
        view = NativeLayout.page([
            NativeLayout.text("权限检查", heading: true),
            NativeLayout.text("当前仅支持触控笔输入。授权完成后会自动尝试启用笔的鼠标控制。"),
            NativeLayout.card([NativeLayout.text("控制与事件发送", heading: true), controlStatus, controlButton]),
            NativeLayout.card([NativeLayout.text("输入监控", heading: true), inputStatus, inputButton]),
            NSButton(title: "重新检查", target: owner, action: #selector(AppDelegate.refreshPermissions)),
            NativeLayout.text("控制权限在 macOS 27 中名为“设备控制和数据访问”，旧系统名为“辅助功能”。输入监控授权后可能需要重新启动应用。已授权的按钮会禁用。")
        ])
    }
    func update(control: Bool, input: Bool, post: Bool) {
        controlStatus.stringValue = "控制权限：\(control ? "已授权" : "未授权") · 鼠标事件发送：\(post ? "已允许" : "未允许")"
        inputStatus.stringValue = "输入监控：\(input ? "已授权" : "未授权")"
        controlStatus.textColor = control && post ? .systemGreen : .systemOrange
        inputStatus.textColor = input ? .systemGreen : .systemOrange
        controlStatus.font = .systemFont(ofSize: 14, weight: .medium)
        inputStatus.font = .systemFont(ofSize: 14, weight: .medium)
        controlButton.isEnabled = !(control && post)
        inputButton.isEnabled = !input
        controlButton.title = control && post ? "控制权限已授权" : "申请控制权限…"
        inputButton.title = input ? "输入监控已授权" : "申请输入监控权限…"
    }
}

/// A labeled native switch with an explicit text state in a full-width row.
final class NativeToggle: NSStackView {
    private let toggle = NSSwitch()
    private let status = NSTextField(labelWithString: "")
    weak var target: AnyObject?
    var action: Selector?
    var statusText: String? { didSet { refreshState() } }
    var state: NSControl.StateValue {
        get { toggle.state }
        set { toggle.state = newValue; refreshState() }
    }
    init(_ title: String) {
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 12; distribution = .fill
        edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggle.setAccessibilityLabel(title)
        toggle.target = self; toggle.action = #selector(changed)
        addArrangedSubview(label); addArrangedSubview(status); addArrangedSubview(toggle)
        refreshState()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refreshState() {
        status.stringValue = statusText ?? (state == .on ? "已开启" : "已关闭")
        status.textColor = statusText != nil ? .systemOrange : (state == .on ? .systemGreen : .secondaryLabelColor)
    }
    @objc private func changed() {
        refreshState()
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}

final class HelpButton: NSButton {
    private let explanation: String
    private var helpPopover: NSPopover?
    init(title: String, explanation: String) {
        self.explanation = explanation
        super.init(frame: .zero)
        bezelStyle = .helpButton
        self.title = ""
        toolTip = title + "说明"
        setAccessibilityLabel(title + "说明")
        target = self; action = #selector(showHelp)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func showHelp() {
        if let helpPopover, helpPopover.isShown { helpPopover.close(); return }
        let label = NativeLayout.text(explanation)
        let width: CGFloat = 320
        let height = ceil((explanation as NSString).boundingRect(with: NSSize(width: width, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)]).height) + 8
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: width + 40, height: height + 40))
        label.frame = NSRect(x: 20, y: 20, width: width, height: height)
        controller.view.addSubview(label)
        let popover = NSPopover()
        popover.behavior = .transient; popover.contentViewController = controller
        helpPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }
}
