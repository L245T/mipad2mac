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

final class SetupWindow {
    private var window: NSWindow?
    private var tabs: NSTabView?
    private let permissionText = NativeLayout.text("")
    private let connectionText = NativeLayout.text("")
    func update(permissions: String, connection: String) {
        permissionText.stringValue = permissions; connectionText.stringValue = connection
    }
    func show(owner: AppDelegate, permissions: Bool = false) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "MiPad2Mac · 使用指引与权限"; w.minSize = NSSize(width: 570, height: 410)
            w.isReleasedWhenClosed = false; w.center()
            let guide = NativeLayout.page([
                NativeLayout.text("开始使用 MiPad2Mac", heading: true),
                NativeLayout.text("1. 连接平板\n使用支持视频和数据的 USB-C 线，进入平板 DP-in。画面通过 DisplayPort 传输。"),
                NativeLayout.text("2. 检查权限\n切换到“权限检查”，分别查看控制权限和输入监控。只有你点击设置按钮时才请求权限。"),
                NativeLayout.text("3. 选择屏幕并启用\n回到主窗口，选择平板显示器，用笔轻点使程序收到数据，再点击“启用鼠标控制”。程序不会自动接管鼠标。"),
                NativeLayout.text("4. 验证位置和轻点\n点击“在平板打开测试页”，检查笔尖与光标是否对应，轻点是否计数。需要时暂停控制后调整方向。"),
                NativeLayout.text("当前支持笔的鼠标操作；手指输入仍待排查。关闭主窗口后程序继续运行，可从菜单栏暂停或退出。"),
                NSButton(title: "进入控制窗口", target: owner, action: #selector(AppDelegate.finishGuide))
            ])
            let permissionPage = NativeLayout.page([
                NativeLayout.text("权限检查", heading: true), permissionText,
                NativeLayout.text("控制权限：用于移动光标和提交点击。macOS 27 中名为“设备控制和数据访问”，旧系统名为“辅助功能”。系统事件发送许可单独列出，以实际检测为准。"),
                NSButton(title: "打开控制权限设置…", target: owner, action: #selector(AppDelegate.requestPermissions)),
                NativeLayout.text("输入监控：用于读取平板 HID 输入，尤其是包含键鼠的诊断接口。授权后可能需要退出并重新打开应用。"),
                NSButton(title: "打开输入监控设置…", target: owner, action: #selector(AppDelegate.requestInputPermission)),
                NSButton(title: "重新检查", target: owner, action: #selector(AppDelegate.refreshPermissions)),
                connectionText,
                NativeLayout.text("权限允许不等于触控已正常；还需确认设备连接、收到报文和目标窗口实际响应。状态会自动刷新。")
            ])
            let t = NativeLayout.tabs([("使用指引", guide), ("权限检查", permissionPage)])
            NativeLayout.install(t, in: w); tabs = t; window = w
        }
        tabs?.selectTabViewItem(at: permissions ? 1 : 0)
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func close() { window?.close() }
}
