import AppKit
import SwiftUI
import MiPadCore
import MiPadUpdateCore
import MiPadUpdateTransport

final class NativeUpdater: ObservableObject {
    @Published private(set) var message = "应用内安装尚未配置信任公钥；可打开发布页面手动下载。"
    @Published private(set) var progress: Double?
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var recoveryDirectory: URL?
    private var release: PublishedRelease?
    private var channel: UpdateChannel = .stable
    private var generation = UUID()
    private var transfer: UpdateTransfer?
    private var candidate: TrustedCandidate?
    private var package: URL?
    private var cache: URL?
    private var installing = false
    private var helper: Process?
    private var prepared: PreparedInstall?
    var installationActive: Bool { installing }
    var canCancel: Bool { busy && transfer != nil }
    var showsAction: Bool { available || UpdateTrust.productionKeys.isEmpty }
    var available: Bool { release?.isNewer(than: appVersion, channel: channel) == true }
    var actionTitle: String { ready ? "安装并重新打开…" : (UpdateTrust.productionKeys.isEmpty ? "打开下载页面" : "下载更新…") }
    func connect(_ app: AppDelegate) {
        app.updateChecker.candidateChanged = { [weak self] release, channel, _ in self?.select(release, channel: channel) }
        discoverRecovery()
        if let directory = validatedRestart() {
            do {
                let t = try PrivateFiles.read(InstallTransaction.self, from: directory.appendingPathComponent("transaction.json"))
                app.startupCoordinator.acceptValidatedUpdateRestart(UpdateRestartContext(transactionID: t.id, source: t.source, mainWindowWasVisible: t.windowVisible))
                app.startupCoordinator.coreInitializationCompleted = { snapshot in
                    do {
                        let receipt = InitializationReceipt(transactionID: t.id, process: try ProcessIdentity(getpid()),
                            target: Bundle.main.bundleURL.standardizedFileURL, version: snapshot.version, build: snapshot.build)
                        try PrivateFiles.write(receipt, to: directory.appendingPathComponent("initialized.json"))
                        UserDefaults.standard.set(max(try t.candidate().update.publicationSequence, Int64(UserDefaults.standard.integer(forKey: "updaterPublicationHighWater.v1"))), forKey: "updaterPublicationHighWater.v1")
                    } catch { self.message = "更新初始化回执未写入；旧版备份已保留。" }
                }
            } catch { message = "更新重启上下文未通过验证；按普通启动处理。" }
        }
    }
    private func validatedRestart() -> URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--mipad-update-transaction"), index + 1 < args.count else { return nil }
        do {
            let directory = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
            let root = try PrivateFiles.root(.applicationSupportDirectory, component: "UpdateTransactions")
            guard directory.deletingLastPathComponent() == root else { return nil }
            let t = try PrivateFiles.read(InstallTransaction.self, from: directory.appendingPathComponent("transaction.json"))
            try t.validatePaths(directory: directory)
            guard t.stage == .relaunching, t.target == Bundle.main.bundleURL.standardizedFileURL,
                  let identity = t.installedIdentity, try FileIdentity(t.target, directory: true) == identity,
                  let process = t.helperProcess, process.isAlive else { return nil }
            try AppValidation.process(process.pid, executable: directory.appendingPathComponent("MiPad2MacUpdater"), identifier: "org.mipad2mac.updater")
            try AppValidation.app(t.target, update: t.candidate().update)
            return directory
        } catch { return nil }
    }
    func select(_ release: PublishedRelease?, channel: UpdateChannel) {
        guard !installing && helper == nil else { return }
        generation = UUID(); transfer?.cancel(); transfer = nil; cleanCache()
        self.release = release; self.channel = channel; candidate = nil; package = nil
        busy = false; ready = false; progress = nil
        message = UpdateTrust.productionKeys.isEmpty ? "应用内安装尚未配置信任公钥；可打开发布页面手动下载。" : "发现更新后，可下载、校验并安装。"
    }
    func perform(_ app: AppDelegate) {
        if ready { confirmInstall(app); return }
        guard !busy else { return }
        guard !UpdateTrust.productionKeys.isEmpty else {
            NSWorkspace.shared.open(release?.downloadURL ?? URL(string: "https://github.com/L245T/mipad2mac/releases")!); return
        }
        guard available, let release else { return }
        guard let assets = release.assets, let manifest = assets.first(where: { $0.name == "mipad2mac-update.json" }),
              assets.filter({ $0.name == manifest.name }).count == 1, manifest.size > 0, manifest.size <= 65_536,
              NetworkPolicy.assetURL(manifest.browser_download_url, tag: release.tag_name, name: manifest.name) else {
            manual("此发布没有可信更新清单，请从发布页面手动安装。", release: release, window: app.window); return
        }
        busy = true; message = "正在验证更新清单…"; let token = generation
        let request = UpdateTransfer(limit: 65_536); transfer = request
        request.result = { [weak self] result in
            guard let self, self.generation == token else { return }; self.transfer = nil
            do {
                let os = ProcessInfo.processInfo.operatingSystemVersion
                #if arch(arm64)
                let arch = "arm64"
                #else
                let arch = "x86_64"
                #endif
                let verified = try UpdateTrust.candidate(try result.get(), release: release, channel: self.channel,
                    currentVersion: appVersion, highWater: Int64(UserDefaults.standard.integer(forKey: "updaterPublicationHighWater.v1")),
                    osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: arch)
                self.candidate = verified; try self.download(verified, token: token)
            } catch { self.busy = false; self.manual(error.localizedDescription, release: release, window: app.window) }
        }
        request.start(manifest.browser_download_url)
    }
    private func download(_ value: TrustedCandidate, token: UUID) throws {
        let root = try PrivateFiles.root(.cachesDirectory, component: "Updates")
        try PrivateFiles.requireSpace(at: root, bytes: value.update.byteLength * 2 + 67_108_864)
        let directory = root.appendingPathComponent(UUID().uuidString); try PrivateFiles.createDirectory(directory); cache = directory
        let file = directory.appendingPathComponent("update.dmg")
        let download = UpdateTransfer(limit: value.update.byteLength, destination: file); transfer = download
        message = "正在下载\(value.update.applicationVersion)…"; progress = 0
        download.progress = { [weak self] progress in if self?.generation == token { self?.progress = progress } }
        download.result = { [weak self] result in
            guard let self, self.generation == token else { return }; self.transfer = nil; self.progress = nil
            do { _ = try result.get() } catch { self.fail(error); return }
            self.message = "正在校验下载文件…"
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try PackageDigest.verify(file, length: value.update.byteLength, hash: value.update.sha256) }
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    do { try result.get(); self.package = file; self.ready = true; self.busy = false
                        self.message = "下载与SHA-256校验通过，可安装并重新打开。"
                    } catch { self.fail(error) }
                }
            }
        }
        download.start(value.asset.browser_download_url)
    }
    func cancel() {
        guard canCancel else { return }; generation = UUID(); transfer?.cancel(); transfer = nil
        busy = false; progress = nil; ready = false; cleanCache(); message = "已取消下载；可重新开始。"
    }
    private func fail(_ error: Error) { installing = false; helper = nil; busy = false; ready = false; progress = nil; message = error.localizedDescription; cleanCache() }
    private func cleanCache() { if let cache { try? FileManager.default.removeItem(at: cache) }; cache = nil; package = nil }
    private func manual(_ reason: String, release: PublishedRelease, window: NSWindow) {
        message = reason
        let alert = NSAlert(); alert.messageText = "请手动安装更新"; alert.informativeText = reason
        alert.addButton(withTitle: "打开发布页面"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn, let url = release.downloadURL { NSWorkspace.shared.open(url) } }
    }
    private func confirmInstall(_ app: AppDelegate) {
        guard !busy, let package, let candidate, let release else { return }
        let alert = NSAlert(); alert.messageText = "安装\(candidate.update.applicationVersion)并重新打开？"
        alert.informativeText = "MiPad2Mac会正常退出、释放笔输入状态，然后安装更新。旧版本将保留为备份，已有偏好不会删除。"
        alert.addButton(withTitle: "安装并重新打开"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: app.window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.busy = true; self.installing = true; self.message = "正在检查安装位置、签名并准备更新…"
            let source = CurrentReleaseIdentity.snapshot(); let visible = app.window.isVisible; let channel = self.channel
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try UpdatePreparation.prepare(package: package, candidate: candidate, release: release,
                    channel: channel, source: source, visible: visible) }
                DispatchQueue.main.async {
                    do { let prepared = try result.get(); self.prepared = prepared; try self.launchHelper(prepared.directory, recover: false, app: app) }
                    catch { self.fail(error) }
                }
            }
        }
    }
    private func launchHelper(_ directory: URL, recover: Bool, app: AppDelegate) throws {
        installing = true
        let process = Process(); let pipe = Pipe()
        process.executableURL = directory.appendingPathComponent("MiPad2MacUpdater")
        process.arguments = [recover ? "--recover" : "--install", directory.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            buffer.append(data)
            guard buffer.count <= 1024 else { handle.readabilityHandler = nil; return }
            guard let line = String(data: buffer, encoding: .utf8), line.contains("\n") else { return }
            handle.readabilityHandler = nil
            DispatchQueue.main.async {
                guard line == "READY \(directory.lastPathComponent)\n" else { return }
                do {
                    let t = try PrivateFiles.read(InstallTransaction.self, from: directory.appendingPathComponent("transaction.json"))
                    guard t.helperProcess?.pid == process.processIdentifier, t.helperProcess?.isAlive == true,
                          t.target == Bundle.main.bundleURL.standardizedFileURL else { throw UpdateFailure.rejected("更新助手握手不匹配。") }
                    try AppValidation.process(process.processIdentifier, executable: process.executableURL!, identifier: "org.mipad2mac.updater")
                    self.message = "正在正常退出，随后安装并重新打开…"
                    self.cleanCache()
                    NSApp.terminate(nil)
                } catch { self.message = error.localizedDescription }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }; self.helper = nil; self.installing = false; self.busy = false
                self.message = "更新助手已结束；请查看更新恢复记录。"; self.discoverRecovery()
            }
        }
        helper = process; try process.run()
    }
    private func discoverRecovery() {
        guard let root = try? PrivateFiles.root(.applicationSupportDirectory, component: "UpdateTransactions"),
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in entries.prefix(128) {
            guard let t = try? PrivateFiles.read(InstallTransaction.self, from: directory.appendingPathComponent("transaction.json")),
                  t.target == Bundle.main.bundleURL.standardizedFileURL,
                  [.replacing, .installed, .relaunching, .pending].contains(t.stage) else { continue }
            recoveryDirectory = directory; message = "上次更新尚未确认。旧版备份已保留，可查看记录或恢复旧版。"; break
        }
    }
    func showRecovery(_ app: AppDelegate) {
        guard let directory = recoveryDirectory else { return }
        let alert = NSAlert(); alert.messageText = "更新恢复"
        alert.informativeText = "查看更新记录可找到旧版备份。恢复会先正常退出当前应用；若其他副本仍在运行，助手会停止。恢复不会删除用户偏好。"
        alert.addButton(withTitle: "查看记录"); alert.addButton(withTitle: "恢复旧版…"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: app.window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(directory) }
            if response == .alertSecondButtonReturn {
                do {
                    try PrivateFiles.write(try ProcessIdentity(getpid()), to: directory.appendingPathComponent("recovery-request.json"))
                    self.busy = true; try self.launchHelper(directory, recover: true, app: app)
                } catch { self.fail(error) }
            }
        }
    }
}
struct NativeUpdateControls: View {
    @ObservedObject var updater: NativeUpdater
    let app: AppDelegate
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(updater.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let value = updater.progress { ProgressView(value: value).accessibilityLabel("更新下载进度") }
            HStack {
                if updater.showsAction { Button(updater.actionTitle) { updater.perform(app) }.disabled(updater.busy || updater.recoveryDirectory != nil) }
                if updater.canCancel { Button("取消下载") { updater.cancel() } }
                if updater.recoveryDirectory != nil { Button("查看更新恢复…") { updater.showRecovery(app) }.disabled(updater.busy) }
            }
        }
    }
}
