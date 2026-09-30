import Foundation
import MiPadCore
import Darwin

public enum InstallStage: String, Codable {
    case prepared, waitingForExit, replacing, installed, relaunching, completed, pending, rolledBack, failed
}
public struct InstallTransaction: Codable {
    public let id: UUID
    public let created: Date
    public let envelope: Data
    public let release: PublishedRelease
    public let channel: String
    public let source: LaunchSnapshot
    public let windowVisible: Bool
    public let target: URL
    public let targetIdentity: FileIdentity
    public let parentIdentity: FileIdentity
    public let workspace: URL
    public let workspaceIdentity: FileIdentity
    public let staged: URL
    public let stagedIdentity: FileIdentity
    public let oldProcess: ProcessIdentity
    public let backupName: String
    public var stage: InstallStage = .prepared
    public var helperProcess: ProcessIdentity?
    public var installedIdentity: FileIdentity?
    public var backupIdentity: FileIdentity?
    public var launchedProcess: ProcessIdentity?
    public var detail: String = ""
    public init(id: UUID, candidate: TrustedCandidate, release: PublishedRelease, channel: UpdateChannel,
                source: LaunchSnapshot, windowVisible: Bool, target: URL, workspace: URL, oldProcess: ProcessIdentity) throws {
        self.id = id; created = Date(); envelope = candidate.envelope; self.release = release; self.channel = channel.rawValue
        self.source = source; self.windowVisible = windowVisible; self.target = target; self.workspace = workspace
        targetIdentity = try FileIdentity(target, directory: true); parentIdentity = try FileIdentity(target.deletingLastPathComponent(), directory: true)
        workspaceIdentity = try FileIdentity(workspace, directory: true, privateOwner: true)
        staged = workspace.appendingPathComponent("MiPad2Mac.app"); stagedIdentity = try FileIdentity(staged, directory: true)
        self.oldProcess = oldProcess; backupName = ".MiPad2Mac-backup-\(id.uuidString).app"
    }
    public var backup: URL { target.deletingLastPathComponent().appendingPathComponent(backupName) }
    public func validatePaths(directory: URL) throws {
        try PrivateFiles.validateAncestors(directory)
        _ = try FileIdentity(directory, directory: true, privateOwner: true)
        guard directory.lastPathComponent == id.uuidString,
              target.lastPathComponent == "MiPad2Mac.app", source.valid,
              backupName == ".MiPad2Mac-backup-\(id.uuidString).app",
              workspace.lastPathComponent == ".MiPad2Mac-update-\(id.uuidString)",
              workspace.deletingLastPathComponent() == target.deletingLastPathComponent(),
              staged == workspace.appendingPathComponent("MiPad2Mac.app"),
              targetIdentity.device == stagedIdentity.device,
              try FileIdentity(target.deletingLastPathComponent(), directory: true) == parentIdentity,
              try FileIdentity(workspace, directory: true, privateOwner: true) == workspaceIdentity else {
            throw UpdateFailure.rejected("更新事务路径或磁盘对象发生变化。")
        }
        try PrivateFiles.validateAncestors(target.deletingLastPathComponent())
    }
    public func candidate(highWater: Int64? = nil) throws -> TrustedCandidate {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard let channel = UpdateChannel(rawValue: channel) else { throw UpdateFailure.rejected("更新渠道无效。") }
        return try UpdateTrust.candidate(envelope, release: release, channel: channel, currentVersion: source.version,
            highWater: highWater ?? Int64(UserDefaults(suiteName: UpdateTrust.bundleID)?.integer(forKey: "updaterPublicationHighWater.v1") ?? 0), osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture)
    }
}
public struct InitializationReceipt: Codable {
    public let transactionID: UUID
    public let process: ProcessIdentity
    public let target: URL
    public let version: String
    public let build: String
    public init(transactionID: UUID, process: ProcessIdentity, target: URL, version: String, build: String) {
        self.transactionID = transactionID; self.process = process; self.target = target; self.version = version; self.build = build
    }
    public func matches(_ transaction: InstallTransaction, update: SignedUpdate) -> Bool {
        transactionID == transaction.id && process == transaction.launchedProcess && process.isAlive &&
        target == transaction.target && version == update.applicationVersion && build == update.buildNumber
    }
}
/// File operations are separately testable using private fixture bundles. Production callers additionally validate code and processes.
public enum Replacement {
    public static func install(_ t: inout InstallTransaction) throws {
        guard try FileIdentity(t.target, directory: true) == t.targetIdentity,
              try FileIdentity(t.staged, directory: true) == t.stagedIdentity,
              !FileManager.default.fileExists(atPath: t.backup.path) else { throw UpdateFailure.rejected("安装对象发生变化或备份已存在。") }
        t.stage = .replacing
        _ = try FileManager.default.replaceItemAt(t.target, withItemAt: t.staged, backupItemName: t.backupName,
                                                 options: [.withoutDeletingBackupItem, .usingNewMetadataOnly])
        t.installedIdentity = try FileIdentity(t.target, directory: true)
        t.backupIdentity = try FileIdentity(t.backup, directory: true)
        guard t.backupIdentity == t.targetIdentity else { throw UpdateFailure.rejected("旧版本备份对象不匹配。") }
        t.stage = .installed
    }
    public static func rollback(_ t: inout InstallTransaction, newProcessAlive: Bool) throws {
        guard !newProcessAlive, let installed = t.installedIdentity, let backup = t.backupIdentity,
              try FileIdentity(t.target, directory: true) == installed,
              try FileIdentity(t.backup, directory: true) == backup, backup == t.targetIdentity else {
            throw UpdateFailure.rejected("无法安全恢复旧版；请保留备份并手动检查。")
        }
        let failedName = ".MiPad2Mac-unconfirmed-\(t.id.uuidString).app"
        guard !FileManager.default.fileExists(atPath: t.target.deletingLastPathComponent().appendingPathComponent(failedName).path) else {
            throw UpdateFailure.rejected("恢复暂存位置已存在。")
        }
        _ = try FileManager.default.replaceItemAt(t.target, withItemAt: t.backup, backupItemName: failedName,
                                                 options: [.withoutDeletingBackupItem, .usingNewMetadataOnly])
        guard try FileIdentity(t.target, directory: true) == t.targetIdentity else { throw UpdateFailure.rejected("恢复后对象不匹配。") }
        t.stage = .rolledBack
    }
}
