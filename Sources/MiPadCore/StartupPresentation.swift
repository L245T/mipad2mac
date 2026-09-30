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
    public let showMigrationNotice: Bool
    public let suppressAutomaticPermissionWindow: Bool
    public static func decide(source: StartupSource, silentLogin: Bool, hasMigrationNotice: Bool) -> Self {
        if hasMigrationNotice { return Self(showMainWindow: false, showMigrationNotice: true, suppressAutomaticPermissionWindow: true) }
        switch source {
        case .user: return Self(showMainWindow: true, showMigrationNotice: false, suppressAutomaticPermissionWindow: false)
        case .loginItem: return Self(showMainWindow: !silentLogin, showMigrationNotice: false, suppressAutomaticPermissionWindow: true)
        case .updater(let context):
            return Self(showMainWindow: context.mainWindowWasVisible, showMigrationNotice: false,
                        suppressAutomaticPermissionWindow: !context.mainWindowWasVisible)
        }
    }
}
public enum StartupPreferences {
    public static let silentLoginKey = "hideMainWindowOnLogin"
    public static func silentLogin(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: silentLoginKey) as? Bool ?? true
    }
}
