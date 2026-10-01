import Foundation
import Testing
@testable import MiPadCore
struct PenApplicationPreferencesTests {
    @Test func emptyConfigurationBrowsesAndShowsCompatibilityFamily() throws {
        let suite = "pen-profiles-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = PenApplicationPreferences(defaults: defaults)
        #expect(profiles.mode(for: "com.example.reader") == .browse)
        #expect(profiles.mode(for: nil) == .pointer)
        #expect(profiles.mode(for: " \n ") == .pointer)
        #expect(profiles.mode(for: "com.adobe.Photoshop.2026") == .drawing)
        #expect(profiles.configuredApplications.map(\.bundleID) == ["com.adobe.photoshop"])
        #expect(profiles.configuredApplications.first?.scopeDescription != nil)
        #expect(!profiles.hasBrowseApplications) // input routing must not depend on this list
        #expect(defaults.object(forKey: "penApplicationInteractionModes") == nil)
        #expect(defaults.object(forKey: "penLongPressExcludedApps") == nil)
    }
    @Test func explicitLegacyChoicesRemainListedAndKeepTheirModes() throws {
        let suite = "pen-profiles-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = PenNavigationPreferences(defaults: defaults)
        navigation.set(.pointer, for: "com.example.Pointer", name: "Pointer")
        navigation.set(.browse, for: "com.example.Browser", name: "Browser")
        LongPressPreferences(defaults: defaults).exclusions = ["com.example.Paint": "Paint"]
        let profiles = PenApplicationPreferences(defaults: defaults)
        #expect(profiles.mode(for: "COM.EXAMPLE.POINTER") == .pointer)
        #expect(profiles.mode(for: "com.example.browser") == .browse)
        #expect(profiles.mode(for: "com.example.paint") == .drawing)
        #expect(profiles.configuredApplications.count == 3)
        #expect(profiles.configuredApplications.first?.bundleID == "com.example.paint")
        #expect(profiles.mode(for: "com.example.new") == .browse)
        #expect(profiles.configuredApplications.count == 3)
    }
    @Test func manualAdditionPersistsAndDuplicateIDsPreserveChoices() throws {
        let suite = "pen-profiles-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = PenApplicationPreferences(defaults: defaults)
        #expect(profiles.add(for: " COM.EXAMPLE.READER \n", name: " Reader ")?.mode == .browse)
        profiles.set(.pointer, for: "com.example.reader", name: "Reader")
        #expect(profiles.add(for: "Com.Example.Reader", name: "Reader renamed")?.mode == .pointer)
        let restored = PenApplicationPreferences(defaults: defaults)
        #expect(restored.configuredApplications.count == 2)
        #expect(restored.configuredApplications.first { $0.bundleID == "com.example.reader" }?.name == "Reader renamed")
        #expect(restored.mode(for: "COM.EXAMPLE.READER") == .pointer)
        #expect(profiles.add(for: "  ", name: "Invalid") == nil)
        // Adding a previously implicit application is an explicit new browse choice.
        #expect(profiles.add(for: "com.adobe.Photoshop.2026", name: "Photoshop 2026")?.mode == .browse)
        #expect(profiles.mode(for: "com.adobe.Photoshop.2025") == .drawing)
    }
    @Test func deletionCleansLegacyRecordsAndKeepsRightClickCompatibility() throws {
        let suite = "pen-profiles-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "com.example.reader"
        defaults.set([id: "pointer", "COM.EXAMPLE.READER": "browse", "other": "pointer"], forKey: "penNavigationApplicationModes")
        defaults.set(["Com.Example.Reader": "Reader", "other": "Other"], forKey: "penNavigationApplicationNames")
        defaults.set(["COM.EXAMPLE.READER": "Reader"], forKey: "penLongPressExcludedApps")
        defaults.set([id: "browse", "COM.EXAMPLE.READER": "drawing"], forKey: "penApplicationInteractionModes")
        defaults.set([id: "Reader", "Com.Example.Reader": "Old Reader"], forKey: "penApplicationInteractionNames")
        let longPress = LongPressPreferences(defaults: defaults)
        longPress.compatibilityEnabled = true
        longPress.compatibilityApplications = ["Com.Example.Reader": "Reader"]
        let profiles = PenApplicationPreferences(defaults: defaults)
        #expect(profiles.mode(for: id) == .browse) // canonical duplicate wins deterministically
        profiles.remove(for: " COM.EXAMPLE.READER ")
        let restored = PenApplicationPreferences(defaults: defaults)
        #expect(restored.mode(for: id) == .browse)
        #expect(restored.applications[id] == nil)
        #expect(restored.mode(for: "other") == .pointer)
        #expect(restored.applications["other"] == "Other")
        for key in ["penNavigationApplicationModes", "penNavigationApplicationNames", "penLongPressExcludedApps",
                    "penApplicationInteractionModes", "penApplicationInteractionNames"] {
            let values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            #expect(!values.keys.contains { $0.lowercased() == id })
        }
        #expect(longPress.compatibilityEnabled)
        #expect(longPress.compatibilityApplications == ["Com.Example.Reader": "Reader"])
        #expect(restored.add(for: id, name: "Reader")?.mode == .browse)
        #expect(restored.applications[id] == "Reader")
        #expect(defaults.stringArray(forKey: "penApplicationRemovedLegacyIDs")?.contains(id) == false)
    }
    @Test func deletedDrawingVersionDoesNotReturnOrChangeOtherVersions() throws {
        let suite = "pen-profiles-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = PenApplicationPreferences(defaults: defaults)
        profiles.set(.drawing, for: "com.adobe.Photoshop.2026", name: "Photoshop 2026")
        profiles.remove(for: "com.adobe.Photoshop.2026")
        #expect(PenApplicationPreferences(defaults: defaults).mode(for: "com.adobe.Photoshop.2026") == .browse)
        #expect(profiles.mode(for: "com.adobe.Photoshop.2025") == .drawing)
        #expect(profiles.configuredApplications.map(\.bundleID) == ["com.adobe.photoshop"])
        #expect(defaults.object(forKey: "penLongPressExcludedApps") == nil)
        // Removing the visible family stops implicit inheritance; exact version choices remain.
        LongPressPreferences(defaults: defaults).exclusions = ["com.adobe.Photoshop": "Photoshop"]
        #expect(profiles.configuredApplications.count == 1)
        profiles.remove(for: "com.adobe.Photoshop")
        #expect(profiles.mode(for: "com.adobe.Photoshop") == .browse)
        #expect(profiles.mode(for: "com.adobe.Photoshop.2025") == .browse)
        #expect(PenApplicationPreferences(defaults: defaults).configuredApplications.isEmpty)
        profiles.set(.drawing, for: "com.adobe.Photoshop.2026", name: "Photoshop 2026")
        #expect(profiles.mode(for: "com.adobe.Photoshop.2026") == .drawing)
        #expect(profiles.configuredApplications.count == 1)
    }
    @Test func storedModesWithoutNamesRemainVisibleAndDrawingSortsFirst() throws {
        let suite = "pen-profiles-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["com.example.missing": "pointer"], forKey: "penNavigationApplicationModes")
        let profiles = PenApplicationPreferences(defaults: defaults)
        profiles.set(.browse, for: "com.example.b", name: "B")
        profiles.set(.pointer, for: "com.example.a", name: "A")
        profiles.set(.drawing, for: "com.example.z", name: "Z")
        #expect(profiles.configuredApplications.map(\.bundleID) == ["com.adobe.photoshop", "com.example.z", "com.example.a", "com.example.b", "com.example.missing"])
        #expect(profiles.applications["com.example.missing"] == "com.example.missing")
        #expect(profiles.mode(for: "com.example.missing") == .pointer)
    }
    @Test func legacyProfilesRemainUsableAndExplicitModeResolvesConflict() throws {
        let suite = "pen-profiles-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = PenNavigationPreferences(defaults: defaults), longPress = LongPressPreferences(defaults: defaults)
        navigation.set(.browse, for: "com.google.Chrome", name: "Chrome")
        longPress.exclusions = ["com.google.Chrome": "Chrome", "com.adobe.Photoshop": "Photoshop"]
        let profiles = PenApplicationPreferences(defaults: defaults)
        #expect(profiles.mode(for: "COM.GOOGLE.CHROME") == .drawing)
        profiles.set(.browse, for: "com.google.Chrome", name: "Chrome")
        #expect(profiles.mode(for: "COM.GOOGLE.CHROME") == .browse)
        #expect(profiles.hasBrowseApplications)
        profiles.set(.pointer, for: "com.adobe.Photoshop.2026", name: "Photoshop 2026")
        let restored = PenApplicationPreferences(defaults: defaults)
        #expect(restored.mode(for: "com.adobe.Photoshop.2026") == .pointer)
        #expect(restored.mode(for: "com.adobe.Photoshop.2025") == .drawing)
        #expect(longPress.excludes("com.google.Chrome")) // migration never deletes legacy user data
        #expect(restored.applications["com.google.chrome"] == "Chrome")
        profiles.set(.drawing, for: "com.google.Chrome", name: "Chrome")
        #expect(!profiles.hasBrowseApplications)
        #expect(restored.mode(for: nil) == .pointer)
    }
    @Test func defaultPersistsWithoutRewritingExplicitOrLegacyChoices() throws {
        let suite = "pen-default-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = PenApplicationPreferences(defaults: defaults)
        profiles.set(.browse, for: "reader", name: "Reader")
        PenNavigationPreferences(defaults: defaults).set(.pointer, for: "legacy", name: "Legacy")
        for mode in PenApplicationMode.allCases {
            profiles.defaultApplicationMode = mode
            let restored = PenApplicationPreferences(defaults: defaults)
            #expect(restored.defaultApplicationMode == mode)
            #expect(restored.mode(for: "new") == mode)
            #expect(restored.mode(for: "reader") == .browse)
            #expect(restored.mode(for: "legacy") == .pointer)
            #expect(restored.mode(for: nil) == .pointer)
            #expect(restored.mode(for: "com.adobe.photoshop.2026") == .drawing)
        }
        defaults.set("invalid", forKey: "penDefaultApplicationMode")
        #expect(profiles.defaultApplicationMode == .browse)
    }
    @Test func newAndDeletedExceptionsFollowCurrentDefault() throws {
        let suite = "pen-default-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = PenApplicationPreferences(defaults: defaults)
        profiles.defaultApplicationMode = .pointer
        #expect(profiles.add(for: "reader", name: "Reader")?.mode == .pointer)
        profiles.defaultApplicationMode = .drawing
        #expect(profiles.add(for: "READER", name: "Reader")?.mode == .pointer)
        profiles.remove(for: "reader")
        #expect(profiles.mode(for: "reader") == .drawing)
        profiles.defaultApplicationMode = .browse
        #expect(PenApplicationPreferences(defaults: defaults).mode(for: "reader") == .browse)
    }
    @Test func visibleFamilyCanBeChangedAndRemovedWithoutDeletingExactVersions() throws {
        let suite = "pen-family-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = PenApplicationPreferences(defaults: defaults)
        profiles.set(.drawing, for: "com.adobe.photoshop.2026", name: "PS2026")
        PenNavigationPreferences(defaults: defaults).set(.pointer, for: "com.adobe.photoshop.2025", name: "PS2025")
        profiles.set(.browse, for: "com.adobe.photoshop", name: "Photoshop（所有版本）")
        #expect(profiles.mode(for: "com.adobe.photoshop.2026") == .drawing)
        #expect(profiles.mode(for: "com.adobe.photoshop.2025") == .pointer)
        #expect(profiles.mode(for: "com.adobe.photoshop.2027") == .browse)
        profiles.defaultApplicationMode = .pointer
        profiles.remove(for: "com.adobe.photoshop")
        let restored = PenApplicationPreferences(defaults: defaults)
        #expect(restored.mode(for: "com.adobe.photoshop.2027") == .pointer)
        #expect(restored.mode(for: "com.adobe.photoshop.2026") == .drawing)
        #expect(restored.configuredApplications.map(\.bundleID) == ["com.adobe.photoshop.2026", "com.adobe.photoshop.2025"])
        #expect(restored.configuredApplications.allSatisfy { $0.scopeDescription == nil })
    }
    @Test func corruptOverridesFallBackToExistingProfiles() throws {
        let suite = "pen-profiles-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PenNavigationPreferences(defaults: defaults).set(.browse, for: "example", name: "Example")
        defaults.set(["example": "bad"], forKey: "penApplicationInteractionModes")
        #expect(PenApplicationPreferences(defaults: defaults).mode(for: "example") == .browse)
    }
    @Test func filePanelsUseDefaultWhileDrawingWindowsKeepTheirException() throws {
        let suite = "pen-panel-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = PenApplicationPreferences(defaults: defaults)
        profiles.set(.drawing, for: "paint", name: "Paint")
        for mode in PenApplicationMode.allCases {
            profiles.defaultApplicationMode = mode
            #expect(profiles.mode(for: .systemFilePanel) == mode)
            #expect(profiles.mode(for: .ordinaryApplication(bundleID: "paint")) == .drawing)
            #expect(profiles.mode(for: .ordinaryApplication(bundleID: "reader")) == mode)
            #expect(profiles.mode(for: .unresolved) == .pointer)
        }
    }
    @Test func panelRecognitionRequiresIdentifierModalRoleProcessAndGeometry() {
        let bounds = CGRect(x: 100, y: 100, width: 880, height: 448), point = CGPoint(x: 300, y: 300)
        func match(_ id: String?, role: String = "AXWindow", subrole: String? = "AXDialog", modal: Bool? = true,
                   pid: Int32 = 12, frame: CGRect? = CGRect(x: 100, y: 100, width: 880, height: 448),
                   layer: Int? = 0, windowPID: Int32? = 12) -> Bool {
            PenSystemFilePanel.matches(PenPanelMetadata(role: role, subrole: subrole, identifier: id,
                isModal: modal, bounds: frame, processID: pid), point: point, windowBounds: bounds,
                windowProcessID: windowPID, windowLayer: layer)
        }
        #expect(match("open-panel")); #expect(match("save-panel"))
        #expect(!match(nil)); #expect(!match("custom-panel")); #expect(!match("open-panel", modal: nil))
        #expect(!match("open-panel", modal: false)); #expect(!match("open-panel", subrole: "AXStandardWindow"))
        #expect(!match("open-panel", role: "AXGroup")); #expect(!match("open-panel", pid: 13))
        #expect(!match("open-panel", windowPID: nil)); #expect(!match("open-panel", frame: nil))
        #expect(!match("open-panel", layer: 3)); #expect(!match("open-panel", pid: 0, windowPID: 0))
        #expect(!match("open-panel", frame: CGRect(x: 200, y: 200, width: 880, height: 448)))
        #expect(match("open-panel", role: "AXSheet", subrole: nil,
                      frame: CGRect(x: 120, y: 120, width: 500, height: 350)))
        #expect(!match("open-panel", role: "AXSheet", subrole: nil,
                       frame: CGRect(x: 120, y: 120, width: 1500, height: 350)))
    }
    @Test func readOnlyTextAndWebCardsScrollWithoutTurningEditorsIntoPages() {
        let text = { (editable: Bool?) in PenHitNode(role: "AXTextArea", valueEditable: editable) }
        let scroll = PenHitNode(role: "AXScrollArea"), window = PenHitNode(role: "AXWindow")
        #expect(PenHitRegion.classify(nodes: [text(false), scroll, window]) == .content)
        #expect(PenHitRegion.classify(nodes: [text(false), window]) == .content)
        #expect(PenHitRegion.classify(nodes: [text(true), scroll, window]) == .chrome)
        #expect(PenHitRegion.classify(nodes: [text(nil), scroll, window]) == .chrome)
        #expect(PenHitRegion.classify(nodes: [text(false), PenHitNode(role: "AXToolbar"), window]) == .chrome)
        #expect(PenHitRegion.classify(roles: ["AXStaticText", "AXButton", "AXGroup", "AXWebArea", "AXWindow"]) == .content)
        #expect(PenHitRegion.classify(roles: ["AXButton", "AXToolbar", "AXWebArea", "AXWindow"]) == .chrome)
        #expect(PenHitRegion.classify(roles: ["AXButton", "AXScrollArea", "AXWindow"]) == .chrome)
        for role in ["AXList", "AXTable", "AXOutline"] {
            #expect(PenHitRegion.classify(roles: ["AXStaticText", "AXRow", role, "AXWindow"]) == .content)
        }
    }
    @Test func windowChromeAndControlsNeverBecomePageScroll() {
        for roles in [["AXStaticText","AXToolbar","AXWindow"],
                      ["AXScrollBar","AXScrollArea","AXWindow"], ["AXSlider","AXScrollArea","AXWindow"],
                      ["AXButton","AXToolbar","AXWebArea","AXWindow"],
                      ["AXTextField","AXWebArea","AXWindow"], ["AXTextArea","AXScrollArea","AXWindow"],
                      ["AXStaticText","AXComboBox","AXWebArea","AXWindow"]] {
            #expect(PenHitRegion.classify(roles: roles) == .chrome)
        }
        #expect(PenHitRegion.classify(roles: ["AXLink","AXStaticText","AXWebArea","AXWindow"]) == .content)
        #expect(PenHitRegion.classify(roles: ["AXGroup","AXScrollArea","AXWindow"]) == .content)
        #expect(PenHitRegion.classify(roles: ["AXUnknown"]) == .unknown)
    }
    @Test func unknownWindowContentIsDistinctFromKnownControls() {
        for roles in [["AXWindow"], ["AXUnknown", "AXWindow"], ["AXGroup", "AXWindow"], []] {
            #expect(PenHitRegion.classify(roles: roles) == .unknown)
        }
        let bounds = CGRect(x: -1000, y: -500, width: 800, height: 600)
        #expect(!UnknownBrowseArea.contains(CGPoint(x: -600, y: -490), in: bounds))
        #expect(UnknownBrowseArea.contains(CGPoint(x: -600, y: -468), in: bounds))
        #expect(!UnknownBrowseArea.contains(CGPoint(x: 0, y: 0), in: bounds))
        #expect(!UnknownBrowseArea.contains(.zero, in: .zero))
    }
    @Test func defaultBrowseRequiresARealOrdinaryWindowAndPreservesControls() {
        let point = CGPoint(x: 100, y: 100), bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        for region in [PenHitRegion.content, .unknown] {
            #expect(PenBrowseRouting.mode(applicationMode: .browse, region: region, point: point,
                windowBounds: bounds, windowLayer: 0, ownWindow: false) == .browse)
            for layer in [Int?.none, -1, 3, 25] {
                #expect(PenBrowseRouting.mode(applicationMode: .browse, region: region, point: point,
                    windowBounds: bounds, windowLayer: layer, ownWindow: false) == .pointer)
            }
            #expect(PenBrowseRouting.mode(applicationMode: .browse, region: region, point: point,
                windowBounds: nil, windowLayer: 0, ownWindow: false) == .pointer)
            #expect(PenBrowseRouting.mode(applicationMode: .browse, region: region, point: point,
                windowBounds: bounds, windowLayer: 0, ownWindow: true) == .pointer)
        }
        #expect(PenBrowseRouting.mode(applicationMode: .browse, region: .content, point: point,
            windowBounds: bounds, windowLayer: 0, ownWindow: true, allowOwnWindow: true) == .browse)
        #expect(PenBrowseRouting.mode(applicationMode: .browse, region: .unknown, point: CGPoint(x: 100, y: 20),
            windowBounds: bounds, windowLayer: 0, ownWindow: false) == .pointer)
        #expect(PenBrowseRouting.mode(applicationMode: .browse, region: .chrome, point: point,
            windowBounds: bounds, windowLayer: 0, ownWindow: false) == .pointer)
        for mode in [PenApplicationMode.pointer, .drawing] {
            #expect(PenBrowseRouting.mode(applicationMode: mode, region: .content, point: point,
                windowBounds: bounds, windowLayer: 0, ownWindow: false) == .pointer)
        }
        #expect(PenBrowseRouting.mode(applicationMode: .browse, region: .content, point: CGPoint(x: -1, y: 100),
            windowBounds: bounds, windowLayer: 0, ownWindow: false) == .pointer)
    }

}
