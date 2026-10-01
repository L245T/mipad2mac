import Foundation

public enum PenApplicationMode: String, CaseIterable {
    case pointer, browse, drawing
    public var title: String {
        switch self { case .pointer: return "指针"; case .browse: return "浏览"; case .drawing: return "绘画" }
    }
    public var explanation: String {
        switch self {
        case .pointer: return "拖动、选字和点击；长按右键按下方全局设置执行。"
        case .browse: return "滑动内容或未知区域滚动，光标跟随笔尖；双击或三击时按住最后一下再拖动可选字。已识别的顶栏、工具栏和输入控件保留普通拖动；未知窗口顶部保留拖动。静止长按按下方全局设置执行。绘画时切换为绘画模式。"
        case .drawing: return "即时落笔，保留拖动及压力与倾斜输出；此应用不滚动、不触发长按右键。压力与倾斜仍遵循全局开关。"
        }
    }
}

/// Bundle IDs are case insensitive; a canonical key wins over duplicate legacy spellings.
enum PenApplicationID {
    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id.isEmpty ? nil : id
    }
    static func dictionary(_ values: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        let keys = values.keys.sorted {
            let firstCanonical = $0 == normalize($0), secondCanonical = $1 == normalize($1)
            if firstCanonical != secondCanonical { return !firstCanonical }
            return $0 < $1
        }
        for key in keys { if let id = normalize(key) { result[id] = values[key] } }
        return result
    }
}

public struct PenApplicationProfile: Equatable {
    public let bundleID: String
    public let name: String
    public let mode: PenApplicationMode
}

/// Explicit profiles override legacy choices. Removing a profile also removes its legacy records.
public final class PenApplicationPreferences {
    public static let defaultMode = PenApplicationMode.browse
    private let defaults: UserDefaults
    private let navigation: PenNavigationPreferences
    private let longPress: LongPressPreferences
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; navigation = PenNavigationPreferences(defaults: defaults)
        longPress = LongPressPreferences(defaults: defaults)
    }
    private func dictionary(_ key: String) -> [String: String] {
        PenApplicationID.dictionary(defaults.dictionary(forKey: key) as? [String: String] ?? [:])
    }
    private var removedLegacyIDs: Set<String> {
        Set((defaults.stringArray(forKey: "penApplicationRemovedLegacyIDs") ?? []).compactMap(PenApplicationID.normalize))
    }
    /// Only stored choices/additions belong in the list; implicit defaults and foreground apps do not.
    /// Drawing rows come first, then names, with Bundle ID breaking name ties.
    public var configuredApplications: [PenApplicationProfile] {
        var names: [String: String] = [:]
        let exclusions = PenApplicationID.dictionary(longPress.configuredExclusions)
        for layer in [exclusions, PenApplicationID.dictionary(navigation.applications),
                      dictionary("penApplicationInteractionNames")] {
            names.merge(layer) { _, newer in newer }
        }
        let ids = Set(names.keys).union(dictionary("penNavigationApplicationModes").keys)
            .union(dictionary("penApplicationInteractionModes").keys).subtracting(removedLegacyIDs)
        return ids.map { id in
            let name = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PenApplicationProfile(bundleID: id, name: name?.isEmpty == false ? name! : id, mode: mode(for: id))
        }.sorted {
            if ($0.mode == .drawing) != ($1.mode == .drawing) { return $0.mode == .drawing }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
    }
    public var applications: [String: String] {
        Dictionary(uniqueKeysWithValues: configuredApplications.map { ($0.bundleID, $0.name) })
    }
    public func mode(for id: String?) -> PenApplicationMode {
        guard let id = PenApplicationID.normalize(id) else { return .pointer }
        if let raw = dictionary("penApplicationInteractionModes")[id],
           let explicit = PenApplicationMode(rawValue: raw) { return explicit }
        if removedLegacyIDs.contains(id) { return Self.defaultMode }
        if longPress.excludes(id) { return .drawing }
        return navigation.configuredMode(for: id).map { $0 == .browse ? .browse : .pointer } ?? Self.defaultMode
    }
    /// Reports explicit browse records, not whether an unconfigured application can browse.
    public var hasBrowseApplications: Bool { applications.keys.contains { mode(for: $0) == .browse } }
    /// Adding an existing choice preserves its mode; a new user record starts in browse.
    @discardableResult public func add(for id: String, name: String) -> PenApplicationProfile? {
        guard let id = PenApplicationID.normalize(id) else { return nil }
        let existing = configuredApplications.first { $0.bundleID == id }
        set(existing?.mode ?? Self.defaultMode, for: id, name: name)
        return configuredApplications.first { $0.bundleID == id }
    }
    public func set(_ mode: PenApplicationMode, for id: String, name: String) {
        guard let id = PenApplicationID.normalize(id) else { return }
        replaceRecord("penApplicationInteractionModes", id: id, value: mode.rawValue)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        replaceRecord("penApplicationInteractionNames", id: id, value: name.isEmpty ? id : name)
        defaults.set(removedLegacyIDs.subtracting([id]).sorted(), forKey: "penApplicationRemovedLegacyIDs")
    }
    public func remove(for id: String) {
        guard let id = PenApplicationID.normalize(id) else { return }
        for key in ["penApplicationInteractionModes", "penApplicationInteractionNames",
                    "penNavigationApplicationModes", "penNavigationApplicationNames"] {
            replaceRecord(key, id: id, value: nil)
        }
        // Do not materialize/remove the built-in Photoshop family rule or unrelated versions.
        if id != "com.adobe.photoshop", defaults.object(forKey: "penLongPressExcludedApps") != nil {
            replaceRecord("penLongPressExcludedApps", id: id, value: nil)
        }
        // An exact tombstone suppresses inherited drawing rules for this deleted application only.
        defaults.set(removedLegacyIDs.union([id]).sorted(), forKey: "penApplicationRemovedLegacyIDs")
    }
    private func replaceRecord(_ key: String, id: String, value: String?) {
        var values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        values = values.filter { PenApplicationID.normalize($0.key) != id }
        if let value { values[id] = value }
        defaults.set(values, forKey: key)
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
        return .unknown
    }
}

/// Geometric fallback only when the application supplies no usable region metadata.
/// The top band protects ordinary window dragging; it does not identify custom toolbars/editors.
public enum UnknownBrowseArea {
    public static func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
        bounds.contains(point) && point.y >= bounds.minY + 32
    }
}

/// Region metadata alone cannot prove that a real, ordinary application window receives the drag.
public enum PenBrowseRouting {
    public static func mode(applicationMode: PenApplicationMode, region: PenHitRegion, point: CGPoint,
                            windowBounds: CGRect?, windowLayer: Int?, ownWindow: Bool,
                            allowOwnWindow: Bool = false) -> PenNavigationMode {
        guard applicationMode == .browse, let bounds = windowBounds, windowLayer == 0,
              bounds.contains(point), !ownWindow || allowOwnWindow else { return .pointer }
        return region == .content || (region == .unknown && UnknownBrowseArea.contains(point, in: bounds))
            ? .browse : .pointer
    }
}
