import AppKit
import Foundation
import Darwin
import MiPadUpdateCore

/// Short-lived, same-user helper. It has no downloader, input device code or privileged service.
final class Installer {
    let directory: URL
    let record: URL
    var transaction: InstallTransaction
    let update: SignedUpdate
    let recovery: Bool
    var targetLock: TargetLock?
    var oldExit: DispatchSourceProcess?
    var newExit: DispatchSourceProcess?
    var receiptWatch: DispatchSourceFileSystemObject?
    var receiptFD: Int32 = -1
    var deadline: DispatchWorkItem?
    var finished = false
    init(directory: URL, recovery: Bool) throws {
        self.directory = directory; self.recovery = recovery
        record = directory.appendingPathComponent("transaction.json")
        let root = try PrivateFiles.root(.applicationSupportDirectory, component: "UpdateTransactions")
        guard directory.deletingLastPathComponent() == root else { throw UpdateFailure.rejected("不是受支持的私有事务路径。") }
        transaction = try PrivateFiles.read(InstallTransaction.self, from: record)
        try transaction.validatePaths(directory: directory)
        update = try transaction.candidate().update
        // The executing helper itself and its original copy must both belong to the pinned publisher.
        let own = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard own == directory.appendingPathComponent("MiPad2MacUpdater") else { throw UpdateFailure.rejected("助手启动路径不匹配。") }
        try AppValidation.signature(own, identifier: "org.mipad2mac.updater")
        try AppValidation.process(getpid(), executable: own, identifier: "org.mipad2mac.updater")
        targetLock = try TargetLock(parent: transaction.target.deletingLastPathComponent())
    }
    func save() throws { try PrivateFiles.write(transaction, to: record) }
    func runningTarget() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == transaction.target && !$0.isTerminated }
    }
    func begin() throws {
        let recordsRoot = directory.deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(at: recordsRoot, includingPropertiesForKeys: nil)
        guard entries.count <= 128 else { throw UpdateFailure.rejected("更新记录超过自动检查上限。") }
        for entry in entries where entry != directory {
            if let other = try? PrivateFiles.read(InstallTransaction.self, from: entry.appendingPathComponent("transaction.json")),
               other.target == transaction.target, [.waitingForExit, .replacing, .installed, .relaunching, .pending].contains(other.stage) {
                throw UpdateFailure.rejected("安装位置有其他未解决的更新事务。")
            }
        }
        transaction.helperProcess = try ProcessIdentity(getpid())
        if recovery {
            let caller = try PrivateFiles.read(ProcessIdentity.self, from: directory.appendingPathComponent("recovery-request.json"))
            guard caller.isAlive else { throw UpdateFailure.rejected("恢复请求的应用已退出。") }
            try AppValidation.process(caller.pid, executable: transaction.target.appendingPathComponent("Contents/MacOS/MiPad2Mac"), identifier: UpdateTrust.bundleID)
            try save()
            let source = DispatchSource.makeProcessSource(identifier: caller.pid, eventMask: .exit, queue: .main)
            oldExit = source
            source.setEventHandler { [weak self] in
                guard let self else { return }
                do { try self.recover() } catch { self.fail(error) }
            }; source.resume()
            print("READY \(transaction.id.uuidString)"); fflush(stdout)
            let timeout = DispatchWorkItem { [weak self] in self?.end(1) }
            deadline = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
            return
        }
        guard transaction.stage == .prepared, abs(transaction.created.timeIntervalSinceNow) < 600,
              transaction.oldProcess.isAlive,
              try FileIdentity(transaction.target, directory: true) == transaction.targetIdentity,
              try FileIdentity(transaction.staged, directory: true) == transaction.stagedIdentity else {
            throw UpdateFailure.rejected("安装事务已过期或材料已发生变化。")
        }
        try AppValidation.signature(transaction.target, identifier: UpdateTrust.bundleID)
        try AppValidation.process(transaction.oldProcess.pid,
            executable: transaction.target.appendingPathComponent("Contents/MacOS/MiPad2Mac"), identifier: UpdateTrust.bundleID)
        try AppValidation.app(transaction.staged, update: update)
        let sourceMetadata = try AppValidation.metadata(transaction.target)
        guard sourceMetadata["CFBundleShortVersionString"] as? String == transaction.source.version,
              sourceMetadata["CFBundleVersion"] as? String == transaction.source.build else {
            throw UpdateFailure.rejected("来源版本与事务不匹配。")
        }
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == UpdateTrust.bundleID && $0.processIdentifier != transaction.oldProcess.pid && !$0.isTerminated
        }
        guard others.isEmpty else { throw UpdateFailure.rejected("请先正常退出其他MiPad2Mac副本。") }
        transaction.stage = .waitingForExit; try save()
        let source = DispatchSource.makeProcessSource(identifier: transaction.oldProcess.pid, eventMask: .exit, queue: .main)
        oldExit = source
        source.setEventHandler { [weak self] in self?.oldDidExit() }; source.resume()
        // Establish the exit observer before telling the caller that normal termination is safe.
        print("READY \(transaction.id.uuidString)"); fflush(stdout)
        deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.transaction.stage = .failed; self.transaction.detail = "旧进程未按时退出；未替换应用。"
            try? self.save(); self.end(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: deadline!)
        if !transaction.oldProcess.isAlive { oldDidExit() }
    }
    func oldDidExit() {
        guard !finished, transaction.stage == .waitingForExit else { return }
        oldExit?.cancel(); oldExit = nil; deadline?.cancel()
        do {
            guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == UpdateTrust.bundleID && !$0.isTerminated }), (try? ProcessIdentity(transaction.oldProcess.pid)) == nil else {
                throw UpdateFailure.rejected("仍有目标进程运行或进程编号已被复用。")
            }
            try transaction.validatePaths(directory: directory)
            try AppValidation.app(transaction.staged, update: update)
            try AppValidation.gatekeeper(transaction.staged)
            try AppValidation.signature(transaction.target, identifier: UpdateTrust.bundleID)
            transaction.stage = .replacing; try save()
            try Replacement.install(&transaction)
            try save()
            try AppValidation.app(transaction.target, update: update)
            try AppValidation.gatekeeper(transaction.target)
            try AppValidation.signature(transaction.backup, identifier: UpdateTrust.bundleID)
            launchNew()
        } catch { fail(error) }
    }
    func launchNew() {
        do {
            transaction.stage = .relaunching; try save()
            let config = NSWorkspace.OpenConfiguration()
            config.activates = transaction.windowVisible; config.createsNewApplicationInstance = true
            config.arguments = ["--mipad-update-transaction", directory.path]
            NSWorkspace.shared.openApplication(at: transaction.target, configuration: config) { [weak self] app, error in
                DispatchQueue.main.async {
                    guard let self, !self.finished else { return }
                    guard error == nil, let app, app.bundleURL?.standardizedFileURL == self.transaction.target,
                          let identity = try? ProcessIdentity(app.processIdentifier) else {
                        self.transaction.detail = "新版启动未确认。"
                        // Launch Services errors can still leave a live process; never overwrite it.
                        if self.runningTarget() { self.pending() } else { self.restore() }
                        return
                    }
                    self.transaction.launchedProcess = identity
                    do {
                        try AppValidation.process(identity.pid, executable: self.transaction.target.appendingPathComponent("Contents/MacOS/MiPad2Mac"), identifier: UpdateTrust.bundleID)
                        try self.save(); self.waitForReceipt()
                    } catch { self.pending() }
                }
            }
        } catch { fail(error) }
    }
    func waitForReceipt() {
        receiptFD = open(directory.path, O_EVTONLY | O_NOFOLLOW)
        guard receiptFD >= 0 else { pending(); return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: receiptFD, eventMask: [.write, .rename, .delete], queue: .main)
        receiptWatch = watcher
        watcher.setEventHandler { [weak self] in self?.checkReceipt() }; watcher.resume()
        if let pid = transaction.launchedProcess?.pid {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            newExit = source; source.setEventHandler { [weak self] in self?.restore() }; source.resume()
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.runningTarget() { self.pending() } else { self.restore() }
        }
        deadline = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        checkReceipt()
    }
    func checkReceipt() {
        guard !finished, let receipt = try? PrivateFiles.read(InitializationReceipt.self, from: directory.appendingPathComponent("initialized.json")),
              receipt.matches(transaction, update: update) else { return }
        do {
            try AppValidation.process(receipt.process.pid, executable: transaction.target.appendingPathComponent("Contents/MacOS/MiPad2Mac"), identifier: UpdateTrust.bundleID)
            try AppValidation.app(transaction.target, update: update)
            transaction.stage = .completed; transaction.detail = "新版已完成核心初始化；备份已保留。"; try save(); end(0)
        } catch { pending() }
    }
    func pending() {
        guard !finished else { return }
        transaction.stage = .pending; transaction.detail = "新版启动尚未确认；保留旧版备份，未自动回滚。"
        try? save(); end(2)
    }
    func recover() throws {
        guard transaction.helperProcess?.pid == getpid(), !transaction.oldProcess.isAlive,
              !runningTarget() else { throw UpdateFailure.rejected("请正常退出目标应用后再恢复；不能覆盖运行中的应用。") }
        // Recover a crash between the filesystem replacement and journal write only by matching recorded objects.
        if transaction.stage == .replacing {
            if (try? FileIdentity(transaction.target, directory: true)) == transaction.stagedIdentity,
               (try? FileIdentity(transaction.backup, directory: true)) == transaction.targetIdentity {
                transaction.installedIdentity = transaction.stagedIdentity; transaction.backupIdentity = transaction.targetIdentity
            } else if (try? FileIdentity(transaction.target, directory: true)) == transaction.targetIdentity {
                transaction.stage = .failed; transaction.detail = "替换尚未发生，旧版保持原位。"; try save(); end(0); return
            } else { throw UpdateFailure.rejected("中断后的磁盘对象不能确认，需手动恢复。") }
        }
        guard [.pending, .installed, .relaunching, .replacing].contains(transaction.stage) else {
            throw UpdateFailure.rejected("此事务没有可安全回滚的安装。")
        }
        restore()
    }
    func restore() {
        guard !finished else { return }
        guard !runningTarget(), transaction.launchedProcess?.isAlive != true else { pending(); return }
        do {
            try transaction.validatePaths(directory: directory)
            try AppValidation.signature(transaction.backup, identifier: UpdateTrust.bundleID)
            let p = try AppValidation.metadata(transaction.backup)
            guard p["CFBundleShortVersionString"] as? String == transaction.source.version,
                  p["CFBundleVersion"] as? String == transaction.source.build else { throw UpdateFailure.rejected("旧版备份的版本不匹配。") }
            try Replacement.rollback(&transaction, newProcessAlive: false)
            try AppValidation.signature(transaction.target, identifier: UpdateTrust.bundleID)
            transaction.detail = "已恢复旧版；用户偏好保持原样。"; try save()
            let config = NSWorkspace.OpenConfiguration(); config.activates = transaction.windowVisible
            NSWorkspace.shared.openApplication(at: transaction.target, configuration: config) { [weak self] _, _ in
                DispatchQueue.main.async { self?.end(1) }
            }
        } catch { transaction.detail = error.localizedDescription; pending() }
    }
    func fail(_ error: Error) {
        transaction.detail = error.localizedDescription
        if transaction.installedIdentity != nil { restore() }
        else {
            // A replacement failure may have changed disk state. Preserve the 'replacing' journal for explicit recovery.
            if transaction.stage != .replacing { transaction.stage = .failed }
            try? save(); end(1)
        }
    }
    func end(_ status: Int32) {
        guard !finished else { return }; finished = true; deadline?.cancel()
        oldExit?.cancel(); newExit?.cancel(); receiptWatch?.cancel()
        if receiptFD >= 0 { close(receiptFD) }
        targetLock = nil
        exit(status)
    }
}
var installer: Installer?
do {
    guard CommandLine.arguments.count == 3, ["--install", "--recover"].contains(CommandLine.arguments[1]) else {
        throw UpdateFailure.rejected("助手仅接受有效更新事务。")
    }
    installer = try Installer(directory: URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL,
                              recovery: CommandLine.arguments[1] == "--recover")
    try installer!.begin()
    RunLoop.main.run()
} catch {
    // No paths, credentials or downloaded payload are logged.
    fputs("更新助手未启动：\(error.localizedDescription)\n", stderr); exit(1)
}
