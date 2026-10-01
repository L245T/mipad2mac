import AppKit
import SwiftUI
import MiPadCore
import UniformTypeIdentifiers

private final class AppPenModesSelection: ObservableObject {
    @Published var selectedID: String? = nil
}

struct AppPenModesPage: View {
    @ObservedObject var model: SettingsPresentation
    @StateObject private var selection = AppPenModesSelection()
    private var profiles: [PenApplicationProfile] { model.app.output.configuredProfiles }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                Text("未设置的应用默认浏览。可为下列应用单独选择笔模式。")
                    .font(.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 10)
                Divider()
                if profiles.isEmpty {
                    Text("点按下方＋添加应用")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    AppPenModesList(profiles: profiles, selectedID: $selection.selectedID) { profile, mode in
                        model.act {
                            model.app.output.setApplicationProfileMode(mode, for: profile.bundleID, name: profile.name)
                            model.app.refreshNavigationMenu()
                        }
                    }.frame(height: min(320, CGFloat(profiles.count) * 40))
                }
                Divider()
                HStack(spacing: 0) {
                    AppPenModeActions(canRemove: selection.selectedID != nil && profiles.contains(where: { $0.bundleID == selection.selectedID }), add: addApplication) {
                        guard let id = selection.selectedID else { return }
                        model.act {
                            model.app.output.removeApplicationProfile(bundleID: id)
                            model.app.refreshNavigationMenu()
                        }
                        selection.selectedID = nil
                    }.frame(width: 53, height: 24)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 1)
                .frame(height: 24)
                .background(Color(nsColor: .labelColor).opacity(0.025))
            }
            .background(Color(nsColor: Self.groupFill))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Spacer()
                ExplanationButton(text: Self.modeHelp, label: "应用输入模式说明")
            }
        }
    }
    private static let groupFill = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return NSColor(white: dark ? (contrast ? 0.24 : 0.18) : (contrast ? 0.92 : 0.965), alpha: 1)
    }
    private func addApplication() {
        guard model.app.window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "添加应用输入模式"; panel.prompt = "添加"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: model.app.window) { response in
            guard response == .OK, let url = panel.url,
                  let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            model.act {
                if model.app.output.addApplicationProfile(bundleID: id, name: name) {
                    selection.selectedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                model.app.refreshNavigationMenu()
            }
        }
    }
    static let modeHelp = "浏览：滑动滚动，轻点单击；双击或三击后，按住最后一下拖动选字。同次拖选不滚动、不触发长按右键。默认使用浏览，无需逐次开启或逐个添加应用。\n\n已识别的顶栏、工具栏和输入控件保留普通操作；未知普通内容可滚动，窗口顶部保留拖动。未知输入框或自定义工具栏也可能滚动，需要普通拖动时可将该应用设为指针。桌面、浮层和无法确认普通应用窗口的区域不启用滚动。\n\n指针：轻点单击，按住移动拖动，连续点按可选字；静止长按按控制页的全局设置执行。\n\n绘画：即时落笔，不滚动、不触发长按及兼容右键；压力与倾斜遵循控制页开关。绘画前可用＋添加应用，再选择绘画。软件不会自动判断绘画用途；原有绘画例外保留。\n\n列表只显示你添加或调整过的应用，绘画模式排在前面。新添加默认浏览，重复添加保留原模式；选择自动保存，并与HID菜单同步。删除只移除此应用的笔模式设置，回到默认浏览，不卸载应用或删除右键兼容设置。"
}

/// AppKit owns selection, keyboard navigation and pop-up menus. Icons are cached per visible list.
struct AppPenModesList: NSViewRepresentable {
    let profiles: [PenApplicationProfile]
    @Binding var selectedID: String?
    let changeMode: (PenApplicationProfile, PenApplicationMode) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.verticalScroller = SettingsScroller()
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("application"))
        table.addTableColumn(column); table.headerView = nil
        table.style = .plain; table.backgroundColor = .clear
        table.rowHeight = 40; table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.autoresizingMask = [.width]
        table.setAccessibilityLabel("应用输入模式列表")
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: AppPenModesList
        weak var table: NSTableView?
        private var rows: [PenApplicationProfile] = []
        private var icons: [String: NSImage] = [:]
        private var updating = false
        init(_ parent: AppPenModesList) { self.parent = parent }
        func update() {
            guard let table else { return }
            updating = true
            if rows != parent.profiles {
                rows = parent.profiles
                let ids = Set(rows.map(\.bundleID))
                icons = icons.filter { ids.contains($0.key) }
                for row in rows where icons[row.bundleID] == nil {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: row.bundleID) {
                        icons[row.bundleID] = NSWorkspace.shared.icon(forFile: url.path)
                    } else {
                        icons[row.bundleID] = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
                    }
                }
                table.reloadData()
            }
            if let index = rows.firstIndex(where: { $0.bundleID == parent.selectedID }) {
                if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            } else { table.deselectAll(nil) }
            updating = false
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let profile = rows[row]
            let cell = NSTableCellView()
            let icon = NSImageView(); icon.image = icons[profile.bundleID]
            icon.imageScaling = .scaleProportionallyUpOrDown
            let name = NSTextField(labelWithString: profile.name)
            name.font = .systemFont(ofSize: 13)
            name.lineBreakMode = .byTruncatingMiddle; name.toolTip = profile.name
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let menu = NSPopUpButton(frame: .zero, pullsDown: false)
            menu.isBordered = false; menu.controlSize = .regular
            menu.font = .systemFont(ofSize: 13)
            for mode in PenApplicationMode.allCases {
                let item = NSMenuItem(title: mode.title, action: nil, keyEquivalent: "")
                item.representedObject = mode.rawValue; menu.menu?.addItem(item)
            }
            menu.selectItem(at: PenApplicationMode.allCases.firstIndex(of: profile.mode) ?? 1)
            menu.identifier = .init(profile.bundleID)
            menu.target = self; menu.action = #selector(modeChanged)
            menu.setAccessibilityLabel(profile.name + "的输入模式")
            cell.imageView = icon; cell.textField = name
            for child in [icon, name, menu] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                name.trailingAnchor.constraint(lessThanOrEqualTo: menu.leadingAnchor, constant: -12),
                name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                menu.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                menu.widthAnchor.constraint(equalToConstant: 76), menu.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            if row < rows.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(separator)
                NSLayoutConstraint.activate([
                    separator.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                    separator.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    separator.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
                    separator.heightAnchor.constraint(equalToConstant: 1)
                ])
            }
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].bundleID : nil
        }
        @objc private func modeChanged(_ sender: NSPopUpButton) {
            guard let id = sender.identifier?.rawValue, let profile = rows.first(where: { $0.bundleID == id }),
                  let raw = sender.selectedItem?.representedObject as? String,
                  let mode = PenApplicationMode(rawValue: raw) else { return }
            parent.selectedID = id
            parent.changeMode(profile, mode)
        }
    }
}

/// Borderless native buttons sit in the group's continuous bottom action strip.
private struct AppPenModeActions: NSViewRepresentable {
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal; stack.spacing = 0; stack.alignment = .centerY
        for (index, symbol) in ["plus", "minus"].enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: context.coordinator, action: index == 0 ? #selector(Coordinator.addApplication(_:)) : #selector(Coordinator.removeApplication(_:)))
            button.isBordered = false; button.controlSize = .small
            button.imagePosition = .imageOnly; button.imageScaling = .scaleNone
            button.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            button.contentTintColor = .secondaryLabelColor
            button.setAccessibilityLabel(index == 0 ? "添加应用" : "移除所选应用的笔模式设置")
            button.toolTip = index == 0 ? "添加应用" : "移除所选应用的笔模式设置，不会卸载应用"
            button.tag = index; button.isEnabled = index == 0 || canRemove
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            if index == 0 {
                let separator = NSBox(); separator.boxType = .separator
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
                separator.heightAnchor.constraint(equalToConstant: 16).isActive = true
            }
        }
        return stack
    }
    func updateNSView(_ stack: NSStackView, context: Context) {
        context.coordinator.parent = self
        if let button = stack.arrangedSubviews.last as? NSButton { button.isEnabled = canRemove }
    }
    final class Coordinator: NSObject {
        var parent: AppPenModeActions
        init(_ parent: AppPenModeActions) { self.parent = parent }
        @objc func addApplication(_ sender: NSButton) { parent.add() }
        @objc func removeApplication(_ sender: NSButton) {
            if parent.canRemove { parent.remove() }
        }
    }
}
