import Foundation
import MiPadCore
import MiPadUpdateCore

struct PreparedInstall {
    let directory: URL
    let transaction: InstallTransaction
}
enum UpdatePreparation {
    static func prepare(package: URL, candidate: TrustedCandidate, release: PublishedRelease, channel: UpdateChannel,
                        source: LaunchSnapshot, visible: Bool) throws -> PreparedInstall {
        try PackageDigest.verify(package, length: candidate.update.byteLength, hash: candidate.update.sha256)
        let target = Bundle.main.bundleURL.standardizedFileURL
        guard target.lastPathComponent == "MiPad2Mac.app", !target.path.hasPrefix("/Volumes/"), source.profile == .developerID else {
            throw UpdateFailure.rejected("请先将正式签名的应用安装到可写位置；当前副本请手动更新。")
        }
        try PrivateFiles.validateAncestors(target)
        try AppValidation.signature(target, identifier: UpdateTrust.bundleID)
        let oldProcess = try ProcessIdentity(ProcessInfo.processInfo.processIdentifier)
        try AppValidation.process(oldProcess.pid, executable: target.appendingPathComponent("Contents/MacOS/MiPad2Mac"), identifier: UpdateTrust.bundleID)
        let parent = target.deletingLastPathComponent()
        try PrivateFiles.requireSpace(at: parent, bytes: candidate.update.byteLength * 4 + 268_435_456)
        let id = UUID()
        let workspace = parent.appendingPathComponent(".MiPad2Mac-update-\(id.uuidString)")
        try PrivateFiles.createDirectory(workspace)
        var transactionDirectory: URL?
        var complete = false
        defer {
            if !complete {
                try? FileManager.default.removeItem(at: workspace)
                if let transactionDirectory { try? FileManager.default.removeItem(at: transactionDirectory) }
            }
        }
        let transactions = try PrivateFiles.root(.applicationSupportDirectory, component: "UpdateTransactions")
        let entries = try FileManager.default.contentsOfDirectory(at: transactions, includingPropertiesForKeys: nil)
        guard entries.count <= 128 else { throw UpdateFailure.rejected("更新记录较多，请先检查已有事务。") }
        for entry in entries {
            if let pending = try? PrivateFiles.read(InstallTransaction.self, from: entry.appendingPathComponent("transaction.json")),
               pending.target == target, [.waitingForExit, .replacing, .installed, .relaunching, .pending].contains(pending.stage) {
                throw UpdateFailure.rejected("该安装位置还有未确认的更新，请先查看恢复记录。")
            }
        }
        let directory = transactions.appendingPathComponent(id.uuidString)
        try PrivateFiles.createDirectory(directory)
        transactionDirectory = directory
        let mount = directory.appendingPathComponent("mount")
        try PrivateFiles.createDirectory(mount)
        let data = try SystemCommand.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-plist", package.path])
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { throw UpdateFailure.rejected("无法读取安装镜像的挂载信息。") }
        let devices = entities.compactMap { $0["dev-entry"] as? String }.filter { $0.hasPrefix("/dev/disk") }
        // Only detach the exact device created by this attach. Never use a path supplied by the image.
        guard let device = devices.first, device.dropFirst(9).allSatisfy({ $0.isNumber || $0 == "s" }) else { throw UpdateFailure.rejected("镜像返回的设备信息异常。") }
        defer { _ = try? SystemCommand.run("/usr/bin/hdiutil", ["detach", device]) }
        let volumes = entities.compactMap { $0["mount-point"] as? String }
        guard volumes == [mount.path] else { throw UpdateFailure.rejected("镜像包含意外卷，不能自动安装。") }
        let apps = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard apps.count == 1, apps[0].lastPathComponent == "MiPad2Mac.app" else { throw UpdateFailure.rejected("镜像应用布局异常。") }
        try AppValidation.app(apps[0], update: candidate.update)
        let contents = FileManager.default.enumerator(at: apps[0], includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var expanded: Int64 = 0; var count = 0
        while let item = contents?.nextObject() as? URL {
            count += 1; let values = try item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { expanded += Int64(values.fileSize ?? 0) }
            guard count <= 100_000, expanded <= 4_294_967_296 else { throw UpdateFailure.rejected("应用包超过展开大小上限。") }
        }
        try PrivateFiles.requireSpace(at: workspace, bytes: expanded * 2 + 268_435_456)
        let staged = workspace.appendingPathComponent("MiPad2Mac.app")
        _ = try SystemCommand.run("/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", apps[0].path, staged.path])
        // Preserve the downloaded image's quarantine on the copied app when present.
        try copyQuarantine(from: package, to: staged)
        try AppValidation.app(staged, update: candidate.update)
        try AppValidation.gatekeeper(staged)
        var transaction = try InstallTransaction(id: id, candidate: candidate, release: release, channel: channel,
            source: source, windowVisible: visible, target: target, workspace: workspace, oldProcess: oldProcess)
        transaction.stage = .prepared
        try PrivateFiles.write(transaction, to: directory.appendingPathComponent("transaction.json"))
        let helper = target.appendingPathComponent("Contents/MacOS/MiPad2MacUpdater")
        try AppValidation.signature(helper, identifier: "org.mipad2mac.updater")
        let copiedHelper = directory.appendingPathComponent("MiPad2MacUpdater")
        _ = try SystemCommand.run("/usr/bin/ditto", [helper.path, copiedHelper.path])
        try AppValidation.signature(copiedHelper, identifier: "org.mipad2mac.updater")
        complete = true
        return PreparedInstall(directory: directory, transaction: transaction)
    }
    private static func copyQuarantine(from source: URL, to destination: URL) throws {
        let key = "com.apple.quarantine"
        let length = getxattr(source.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        if length < 0 {
            guard errno == ENOATTR else { throw UpdateFailure.rejected("不能读取下载文件的隔离属性。") }; return
        }
        guard length <= 65_536 else { throw UpdateFailure.rejected("下载文件的隔离属性异常。") }
        var bytes = [UInt8](repeating: 0, count: length)
        guard getxattr(source.path, key, &bytes, length, 0, XATTR_NOFOLLOW) == length,
              setxattr(destination.path, key, bytes, length, 0, XATTR_NOFOLLOW) == 0 else {
            throw UpdateFailure.rejected("不能保留下载隔离属性。")
        }
    }
}
