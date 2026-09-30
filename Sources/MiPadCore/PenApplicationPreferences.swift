import Foundation

public enum PenApplicationMode: String, CaseIterable {
    case pointer, browse, drawing
    public var title: String {
        switch self { case .pointer: return "指针"; case .browse: return "浏览"; case .drawing: return "绘画" }
    }
    public var explanation: String {
        switch self {
        case .pointer: return "拖动、选字和点击；长按右键按下方全局设置执行。"
        case .browse: return "滑动内容滚动，光标跟随笔尖；双击或三击时按住最后一下再拖动可选字。顶栏、工具栏和输入控件保留普通拖动，静止长按按下方全局设置执行。绘画时切换为绘画模式。"
        case .drawing: return "即时落笔，保留拖动及压力与倾斜输出；此应用不滚动、不触发长按右键。压力与倾斜仍遵循全局开关。"
        }
    }
}

/// New explicit profiles override the legacy navigation/exclusion pair. Legacy data stays intact.
public final class PenApplicationPreferences {
    private let defaults: UserDefaults
    private let navigation: PenNavigationPreferences
    private let longPress: LongPressPreferences
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; navigation = PenNavigationPreferences(defaults: defaults)
        longPress = LongPressPreferences(defaults: defaults)
    }
    public var applications: [String: String] {
        var result: [String: String] = [:]
        for dictionary in [longPress.exclusions, navigation.applications,
                           defaults.dictionary(forKey: "penApplicationInteractionNames") as? [String: String] ?? [:]] {
            for (id, name) in dictionary { result[id.lowercased()] = name }
        }
        return result
    }
    public func mode(for id: String?) -> PenApplicationMode {
        guard let id, !id.isEmpty else { return .pointer }
        if let raw = (defaults.dictionary(forKey: "penApplicationInteractionModes") as? [String: String])?[id.lowercased()],
           let explicit = PenApplicationMode(rawValue: raw) { return explicit }
        if longPress.excludes(id) { return .drawing }
        return navigation.mode(for: id) == .browse ? .browse : .pointer
    }
    public var hasBrowseApplications: Bool { applications.keys.contains { mode(for: $0) == .browse } }
    public func set(_ mode: PenApplicationMode, for id: String, name: String) {
        guard !id.isEmpty else { return }
        var modes = defaults.dictionary(forKey: "penApplicationInteractionModes") as? [String: String] ?? [:]
        modes[id.lowercased()] = mode.rawValue
        defaults.set(modes, forKey: "penApplicationInteractionModes")
        var names = defaults.dictionary(forKey: "penApplicationInteractionNames") as? [String: String] ?? [:]
        names[id.lowercased()] = name
        defaults.set(names, forKey: "penApplicationInteractionNames")
    }
}

/// Metadata only: no accessible text or value is retained.
public struct PenHitNode: Equatable {
    public let role: String
    public let valueEditable: Bool?
    public init(role: String, valueEditable: Bool? = nil) {
        self.role = role; self.valueEditable = valueEditable
    }
}

/// AX ancestry is sampled once at contact start, not continuously while the cursor moves.
public enum PenHitRegion: Equatable {
    case content, chrome, unknown
    public static func classify(roles: [String]) -> Self {
        classify(nodes: roles.map { PenHitNode(role: $0) })
    }
    public static func classify(nodes: [PenHitNode]) -> Self {
        let containers = ["AXWebArea", "AXScrollArea", "AXList", "AXTable", "AXOutline", "AXBrowser"]
        let boundary = nodes.firstIndex { containers.contains($0.role) }
        let prefix = boundary.map { Array(nodes.prefix($0 + 1)) } ?? nodes
        let inWeb = prefix.last?.role == "AXWebArea"
        let controls = ["AXToolbar", "AXTitleBar", "AXScrollBar", "AXMenuBar", "AXMenu", "AXMenuItem", "AXTabGroup",
                        "AXSlider", "AXCheckBox", "AXRadioButton", "AXComboBox", "AXPopUpButton"]
        var readOnlyText = false
        for node in prefix {
            if controls.contains(node.role) { return .chrome }
            if node.role == "AXTextField" || node.role == "AXTextArea" {
                // Unavailable metadata must never turn an editor into a scroll gesture.
                guard node.valueEditable == false else { return .chrome }
                readOnlyText = true
            }
            // Web cards often expose a button wrapper around ordinary display text.
            // A short tap still clicks; only a browse drag is interpreted as scrolling.
            if node.role == "AXButton" && !inWeb { return .chrome }
        }
        if boundary != nil || readOnlyText { return .content }
        return nodes.contains { $0.role == "AXWindow" } ? .chrome : .unknown
    }
}
