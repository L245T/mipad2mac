import Foundation
import Testing
@testable import MiPadCore

struct StartupPresentationTests {
    @Test func manualOpenRoutesByPermissionInsteadOfPendingNotice() {
        for notice in [false, true] {
            let decision = StartupPresentation.decide(source: .user, hasMigrationNotice: notice)
            #expect(decision.showMainWindow)
            #expect(!decision.suppressAutomaticPermissionWindow)
            #expect(decision.showMigrationNotice == notice)
            #expect(decision.shouldSelectPermissions(permissionsReady: false))
            #expect(!decision.shouldSelectPermissions(permissionsReady: true))
        }
    }
    @Test func loginAlwaysStaysSilentRegardlessOfNoticeOrPermission() {
        for notice in [false, true] {
            let decision = StartupPresentation.decide(source: .loginItem, hasMigrationNotice: notice)
            #expect(!decision.showMainWindow)
            #expect(!decision.showMigrationNotice)
            #expect(decision.suppressAutomaticPermissionWindow)
            for ready in [false, true] {
                #expect(!decision.shouldSelectPermissions(permissionsReady: ready))
            }
        }
    }
    @Test func trustedUpdaterRestoresVisibilityWithoutMigrationOverride() {
        let source = LaunchSnapshot(version: "0.5.3", build: "24", profile: .localDevelopment, authorizationGeneration: 0, ruleGeneration: 1)
        for visible in [true, false] {
            let context = UpdateRestartContext(transactionID: UUID(), source: source, mainWindowWasVisible: visible)
            for notice in [false, true] {
                let decision = StartupPresentation.decide(source: .updater(context), hasMigrationNotice: notice)
                #expect(decision.showMainWindow == visible)
                #expect(decision.showMigrationNotice == (visible && notice))
                #expect(decision.suppressAutomaticPermissionWindow == !visible)
                for ready in [false, true] {
                    #expect(decision.shouldSelectPermissions(permissionsReady: ready) == (visible && !ready))
                }
            }
        }
    }
}
