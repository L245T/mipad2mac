import Foundation
import Testing
@testable import MiPadCore

struct StartupPresentationTests {
    @Test func manualAlwaysVisibleAndLoginChoiceDoesNotAffectManual() {
        for silent in [true, false] {
            let decision = StartupPresentation.decide(source: .user, silentLogin: silent, hasMigrationNotice: false)
            #expect(decision.showMainWindow && !decision.suppressAutomaticPermissionWindow)
        }
    }
    @Test func loginHidesOnlyWhenChosenAndNeverAddsPermissionPopup() {
        let silent = StartupPresentation.decide(source: .loginItem, silentLogin: true, hasMigrationNotice: false)
        #expect(!silent.showMainWindow && silent.suppressAutomaticPermissionWindow)
        let visible = StartupPresentation.decide(source: .loginItem, silentLogin: false, hasMigrationNotice: false)
        #expect(visible.showMainWindow && visible.suppressAutomaticPermissionWindow)
    }
    @Test func updaterRestoresVisibilityAndMigrationIsSingleException() {
        let source = LaunchSnapshot(version: "0.5.3", build: "24", profile: .localDevelopment, authorizationGeneration: 0, ruleGeneration: 1)
        for visible in [true, false] {
            let context = UpdateRestartContext(transactionID: UUID(), source: source, mainWindowWasVisible: visible)
            #expect(StartupPresentation.decide(source: .updater(context), silentLogin: true, hasMigrationNotice: false).showMainWindow == visible)
            let notice = StartupPresentation.decide(source: .updater(context), silentLogin: true, hasMigrationNotice: true)
            #expect(!notice.showMainWindow && notice.showMigrationNotice && notice.suppressAutomaticPermissionWindow)
        }
        let loginNotice = StartupPresentation.decide(source: .loginItem, silentLogin: true, hasMigrationNotice: true)
        #expect(loginNotice.showMigrationNotice && !loginNotice.showMainWindow)
    }
    @Test func silentPreferenceDefaultsOnAndRestoresWithoutRegisteringLogin() {
        let suite = "MiPadStartupTests." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!; defer { d.removePersistentDomain(forName: suite) }
        #expect(StartupPreferences.silentLogin(in: d))
        d.set(false, forKey: StartupPreferences.silentLoginKey)
        #expect(!StartupPreferences.silentLogin(in: d))
    }
}
