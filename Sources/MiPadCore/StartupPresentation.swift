import Foundation

/// Construct only after the updater verifies its private transaction. No command-line parser grants this trust.
public struct UpdateRestartContext: Equatable {
    public let transactionID: UUID
    public let source: LaunchSnapshot
    public let mainWindowWasVisible: Bool
    public init(transactionID: UUID, source: LaunchSnapshot, mainWindowWasVisible: Bool) {
        self.transactionID = transactionID; self.source = source; self.mainWindowWasVisible = mainWindowWasVisible
    }
}
public enum StartupSource: Equatable { case user, loginItem, updater(UpdateRestartContext) }
public struct StartupPresentation: Equatable {
    public let showMainWindow: Bool
    /// A pending notice is available in the permission page; it never forces that page or a window open.
    public let showMigrationNotice: Bool
    public let suppressAutomaticPermissionWindow: Bool
    public func shouldSelectPermissions(permissionsReady: Bool) -> Bool {
        showMainWindow && !permissionsReady
    }
    public static func decide(source: StartupSource, hasMigrationNotice: Bool) -> Self {
        switch source {
        case .user: return Self(showMainWindow: true, showMigrationNotice: hasMigrationNotice, suppressAutomaticPermissionWindow: false)
        case .loginItem: return Self(showMainWindow: false, showMigrationNotice: false, suppressAutomaticPermissionWindow: true)
        case .updater(let context):
            return Self(showMainWindow: context.mainWindowWasVisible, showMigrationNotice: context.mainWindowWasVisible && hasMigrationNotice,
                        suppressAutomaticPermissionWindow: !context.mainWindowWasVisible)
        }
    }
}
