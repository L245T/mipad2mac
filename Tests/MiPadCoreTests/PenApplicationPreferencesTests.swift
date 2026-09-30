import Foundation
import Testing
@testable import MiPadCore
struct PenApplicationPreferencesTests {
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
    @Test func corruptOverridesFallBackToExistingProfiles() throws {
        let suite = "pen-profiles-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PenNavigationPreferences(defaults: defaults).set(.browse, for: "example", name: "Example")
        defaults.set(["example": "bad"], forKey: "penApplicationInteractionModes")
        #expect(PenApplicationPreferences(defaults: defaults).mode(for: "example") == .browse)
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
        for roles in [["AXWindow"], ["AXStaticText","AXToolbar","AXWindow"],
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
}
