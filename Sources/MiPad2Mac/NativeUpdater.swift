import AppKit
import SwiftUI
import MiPadCore
import MiPadUpdateCore
import MiPadUpdateTransport

final class NativeUpdater: ObservableObject {
    @Published private(set) var phase: NativeUpdatePhase = UpdateTrust.productionKeys.isEmpty ? .manual : .idle
    @Published private(set) var message = UpdateTrust.productionKeys.isEmpty ? "当前版本请从下载页面下载并手动安装更新。" : "检查更新后，可下载新版本。"
    @Published private(set) var detail: String?
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
    var actionTitle: String { phase == .failed && !UpdateTrust.productionKeys.isEmpty ? "重新下载…" : (ready ? "安装并重新打开…" : (UpdateTrust.productionKeys.isEmpty ? "前往下载页面…" : "下载更新…")) }
    var manualDownloadURL: URL { release?.downloadURL ?? URL(string: "https://github.com/L245T/mipad2mac/releases")! }
    var displayVersion: String? { release?.tag_name }
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
                    } catch { self.phase = .warning; self.message = "新版已打开，但更新完成状态未能记录。请保留旧版备份，并查看更新记录。"; self.detail = error.localizedDescription }
                }
            } catch { phase = .warning; message = "更新启动信息未通过校验，已按普通方式打开。请查看更新记录。"; detail = error.localizedDescription }
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
        detail = nil
        phase = UpdateTrust.productionKeys.isEmpty ? .manual : (available ? .available : .idle)
        message = UpdateTrust.productionKeys.isEmpty ? "当前版本请从下载页面下载并手动安装更新。" : (available ? "下载完成后会检查文件，再由你确认安装。" : "检查更新后，可下载新版本。")
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
        busy = true; phase = .manifest; detail = nil; message = "正在确认此更新是否可用…"; let token = generation
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
        phase = .downloading; message = "正在下载\(value.update.applicationVersion)…"; progress = 0
        download.progress = { [weak self] progress in if self?.generation == token { self?.progress = progress } }
        download.result = { [weak self] result in
            guard let self, self.generation == token else { return }; self.transfer = nil; self.progress = nil
            do { _ = try result.get() } catch { self.fail(error); return }
            self.phase = .checkingFile; self.message = "正在检查下载文件是否完整…"
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try PackageDigest.verify(file, length: value.update.byteLength, hash: value.update.sha256) }
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    do { try result.get(); self.package = file; self.ready = true; self.busy = false
                        self.phase = .ready; self.message = "下载文件已校验。安装前还会检查应用和安装位置。"
                    } catch { self.fail(error) }
                }
            }
        }
        download.start(value.asset.browser_download_url)
    }
    func cancel() {
        guard canCancel else { return }; generation = UUID(); transfer?.cancel(); transfer = nil
        busy = false; progress = nil; ready = false; cleanCache(); phase = .cancelled; detail = nil; message = "已取消此次更新，可重新开始。"
    }
    private func fail(_ error: Error) { installing = false; helper = nil; busy = false; ready = false; progress = nil; phase = .failed; message = "更新未完成。可重试，或从下载页面手动安装。"; detail = error.localizedDescription; cleanCache() }
    private func cleanCache() { if let cache { try? FileManager.default.removeItem(at: cache) }; cache = nil; package = nil }
    private func manual(_ reason: String, release: PublishedRelease, window: NSWindow) {
        phase = .manual; message = "此更新目前需从下载页面手动安装。"; detail = reason
        let alert = NSAlert(); alert.messageText = "请手动安装更新"
        alert.informativeText = "当前无法通过应用内安装此更新。请前往下载页面，下载后用新版替换已安装的MiPad2Mac。已有设置会保留。"
        alert.addButton(withTitle: "前往下载页面"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn, let url = release.downloadURL { NSWorkspace.shared.open(url) } }
    }
    private func confirmInstall(_ app: AppDelegate) {
        guard !busy, let package, let candidate, let release else { return }
        let alert = NSAlert(); alert.messageText = "安装\(candidate.update.applicationVersion)并重新打开？"
        alert.informativeText = "安装前还会检查应用和安装位置。MiPad2Mac将正常退出并释放笔输入，安装后重新打开。旧版会保留为备份，已有设置会保留。安装开始后不能中途取消。"
        alert.addButton(withTitle: "安装并重新打开"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: app.window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.busy = true; self.installing = true; self.phase = .preparing; self.message = "正在检查应用、安装位置和可用空间…"
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
                    self.phase = .exiting; self.message = recover ? "正在正常退出MiPad2Mac，随后恢复旧版并重新打开…" : "正在正常退出MiPad2Mac，随后安装并重新打开…"
                    self.cleanCache()
                    NSApp.terminate(nil)
                } catch { self.phase = .warning; self.message = "更新准备未完成，请查看详细信息。"; self.detail = error.localizedDescription }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }; self.helper = nil; self.installing = false; self.busy = false
                self.phase = .warning; self.message = "更新进程已结束，尚未确认完成。若出现恢复入口，请先查看记录。"; self.discoverRecovery()
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
            recoveryDirectory = directory; phase = .recovery; message = "上次更新尚未确认完成。请先查看记录，确认应用和备份状态。"; break
        }
    }
    func showRecovery(_ app: AppDelegate) {
        guard let directory = recoveryDirectory else { return }
        let alert = NSAlert(); alert.messageText = "检查上次更新"
        alert.informativeText = "先查看记录，确认应用与备份的位置。恢复旧版会正常退出当前应用，并保留已有设置；其他副本仍在运行或校验未通过时，恢复会停止，不会覆盖仍在运行的新版。"
        alert.addButton(withTitle: "查看记录"); alert.addButton(withTitle: "恢复旧版…"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: app.window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(directory) }
            if response == .alertSecondButtonReturn {
                do {
                    try PrivateFiles.write(try ProcessIdentity(getpid()), to: directory.appendingPathComponent("recovery-request.json"))
                    self.busy = true; self.phase = .preparing; self.message = "正在检查旧版备份并准备恢复…"; try self.launchHelper(directory, recover: true, app: app)
                } catch { self.fail(error) }
            }
        }
    }
}
enum NativeUpdatePhase {
    case idle, manual, available, manifest, downloading, checkingFile, ready, preparing, exiting, cancelled, failed, warning, recovery
    var title: String {
        switch self {
        case .idle: return "等待检查"
        case .manual: return "手动安装更新"
        case .available: return "可下载更新"
        case .manifest: return "正在确认更新"
        case .downloading: return "正在下载"
        case .checkingFile: return "正在校验文件"
        case .ready: return "准备安装"
        case .preparing: return "正在准备"
        case .exiting: return "正在退出应用"
        case .cancelled: return "已取消更新"
        case .failed: return "更新未完成"
        case .warning: return "更新状态待确认"
        case .recovery: return "检查上次更新"
        }
    }
    var allowsPrimaryAction: Bool {
        switch self {
        case .manual, .available, .ready, .cancelled, .failed: return true
        default: return false
        }
    }
    var symbol: String {
        switch self {
        case .failed: return "exclamationmark.circle"
        case .warning, .recovery: return "exclamationmark.triangle"
        case .ready: return "checkmark.circle"
        default: return "arrow.down.circle"
        }
    }
    var color: Color {
        switch self {
        case .failed: return .red
        case .warning, .recovery: return .orange
        case .cancelled, .idle: return .secondary
        default: return .accentColor
        }
    }
}

private final class NativeUpdateDetailState: ObservableObject { @Published var expanded = false }

struct NativeUpdateControls: View {
    @ObservedObject var updater: NativeUpdater
    let app: AppDelegate
    var body: some View {
        if updater.showsAction || updater.busy || updater.detail != nil || updater.recoveryDirectory != nil {
            NativeUpdateStatus(phase: updater.phase, version: updater.available ? updater.displayVersion : nil,
                message: updater.message, detail: updater.detail, progress: updater.progress, busy: updater.busy,
                showsAction: updater.showsAction && updater.phase.allowsPrimaryAction, actionTitle: updater.actionTitle,
                actionEnabled: !updater.busy && updater.recoveryDirectory == nil,
                manualURL: updater.phase == .failed || updater.phase == .warning ? updater.manualDownloadURL : nil,
                canCancel: updater.canCancel, hasRecovery: updater.recoveryDirectory != nil,
                perform: { updater.perform(app) }, cancel: { updater.cancel() }, recover: { updater.showRecovery(app) })
        }
    }
}

/// Presentation-only snapshot; isolated previews can exercise states without an installer or permission APIs.
struct NativeUpdateStatus: View {
    let phase: NativeUpdatePhase
    var version: String?
    let message: String
    var detail: String?
    var progress: Double?
    var busy: Bool
    var showsAction: Bool
    var actionTitle: String
    var actionEnabled: Bool
    var manualURL: URL?
    var canCancel: Bool
    var hasRecovery: Bool
    var perform: () -> Void
    var cancel: () -> Void
    var recover: () -> Void
    @StateObject private var details = NativeUpdateDetailState()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(version.map { phase.title + " · " + $0 } ?? phase.title, systemImage: phase.symbol)
                    .font(.callout.weight(.semibold)).foregroundStyle(phase.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if hasRecovery {
                    Button("查看更新记录…", action: recover).disabled(busy)
                } else if showsAction && !busy {
                    Button(actionTitle, action: perform).disabled(!actionEnabled)
                }
                if canCancel { Button(phase == .manifest ? "取消" : "取消下载", action: cancel) }
            }
            Text(message).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress).accessibilityLabel("更新下载进度")
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            } else if busy {
                ProgressView().controlSize(.small).accessibilityLabel(phase.title)
            }
            if let manualURL, !busy && !hasRecovery { Link("前往下载页面手动安装…", destination: manualURL).font(.callout) }
            if let detail {
                DisclosureGroup("详细信息", isExpanded: $details.expanded) {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }.font(.callout)
            }
        }.padding(.vertical, 3)
    }
}
