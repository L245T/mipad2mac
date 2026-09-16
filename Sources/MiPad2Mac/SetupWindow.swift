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
        for view in views where view is NSTextField || view is NSPopUpButton {
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
            controlStatus, controlButton, inputStatus, inputButton,
            NSButton(title: "重新检查", target: owner, action: #selector(AppDelegate.refreshPermissions)),
            NativeLayout.text("控制权限在 macOS 27 中名为“设备控制和数据访问”，旧系统名为“辅助功能”。输入监控授权后可能需要重新启动应用。已授权的按钮会禁用。")
        ])
    }
    func update(control: Bool, input: Bool, post: Bool) {
        controlStatus.stringValue = "控制权限：\(control ? "已授权" : "未授权") · 鼠标事件发送：\(post ? "已允许" : "未允许")"
        inputStatus.stringValue = "输入监控：\(input ? "已授权" : "未授权")"
        controlButton.isEnabled = !(control && post)
        inputButton.isEnabled = !input
        controlButton.title = control && post ? "控制权限已授权" : "申请控制权限…"
        inputButton.title = input ? "输入监控已授权" : "申请输入监控权限…"
    }
}
