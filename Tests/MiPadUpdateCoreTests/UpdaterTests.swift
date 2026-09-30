import Foundation
import Testing
import CryptoKit
import MiPadCore
@testable import MiPadUpdateCore

final class UpdaterTests {
    private var temporaryRoots: [URL] = []
    deinit { for root in temporaryRoots { try? FileManager.default.removeItem(at: root) } }
    private func assertEqual<T: Equatable>(_ a: T, _ b: T) { #expect(a == b) }
    private func assertTrue(_ value: Bool) { #expect(value) }
    private func assertFalse(_ value: Bool) { #expect(!value) }
    private func assertThrows<T>(_ body: @autoclosure () throws -> T, _ message: String = "") {
        do { _ = try body(); Issue.record("Expected rejection: \(message)") } catch {}
    }
    private func assertNoThrow<T>(_ body: @autoclosure () throws -> T) {
        do { _ = try body() } catch { Issue.record("Unexpected error: \(error)") }
    }
    private let key = Curve25519.Signing.PrivateKey()
    private func fields() -> [String: Any] {
        ["schemaVersion": 1, "repository": "L245T/mipad2mac", "releaseID": 10, "tag": "v0.6.0", "applicationVersion": "0.6.0",
         "buildNumber": "25", "channel": "stable", "bundleIdentifier": "org.mipad2mac.app", "assetID": 11,
         "assetName": "MiPad2Mac-0.6.0.dmg", "byteLength": 3, "sha256": String(repeating: "a", count: 64),
         "minimumOS": "13.0", "architectures": ["arm64"], "installerProtocol": 1, "publicationSequence": 100,
         "targetIdentityProfile": "developer-id-v1"]
    }
    private func signed(_ fields: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: fields)
        return try JSONEncoder().encode(ManifestEnvelope(payloadBase64: payload.base64EncodedString(),
            signatureBase64: key.signature(for: payload).base64EncodedString(), keyID: "fixture-only"))
    }
    private func release(_ fields: [String: Any]? = nil) -> PublishedRelease {
        let f = fields ?? self.fields()
        return PublishedRelease(tag_name: f["tag"] as! String, draft: false, prerelease: f["channel"] as! String == "beta", id: f["releaseID"] as? Int,
            assets: [ReleaseAsset(id: f["assetID"] as! Int, name: f["assetName"] as! String, size: Int64(f["byteLength"] as! Int),
                browser_download_url: URL(string: "https://github.com/L245T/mipad2mac/releases/download/\(f["tag"]!)/\(f["assetName"]!)")!)])
    }
    private func verify(_ data: Data, release: PublishedRelease? = nil, highWater: Int64 = 0, os: String = "27.0", architecture: String = "arm64", channel: UpdateChannel = .stable) throws -> TrustedCandidate {
        try UpdateTrust.candidate(data, release: release ?? self.release(), channel: channel, currentVersion: "0.5.3", highWater: highWater,
            osVersion: os, architecture: architecture, keys: ["fixture-only": key.publicKey.rawRepresentation])
    }
    @Test func testAuthenticManifestAndRawByteSignature() throws {
        let data = try signed(fields()); assertEqual(try verify(data).update.applicationVersion, "0.6.0")
        var envelope = try JSONDecoder().decode(ManifestEnvelope.self, from: data)
        let altered = Data((" " + String(data: Data(base64Encoded: envelope.payloadBase64)!, encoding: .utf8)!).utf8)
        envelope = ManifestEnvelope(payloadBase64: altered.base64EncodedString(), signatureBase64: envelope.signatureBase64, keyID: envelope.keyID)
        assertThrows(try verify(JSONEncoder().encode(envelope)))
        assertThrows(try UpdateTrust.decode(data, keys: UpdateTrust.productionKeys))
        assertTrue(UpdateTrust.productionKeys.isEmpty)
    }
    @Test func testRejectsTrustProtocolIdentityAndReplayChanges() throws {
        for (name, value) in [("schemaVersion", 2 as Any), ("installerProtocol", 2), ("repository", "attacker/app"),
                              ("bundleIdentifier", "other.app"), ("targetIdentityProfile", "untrusted"), ("publicationSequence", -1),
                              ("byteLength", 2_000_000_000), ("sha256", "wrong"), ("minimumOS", "99.0"), ("architectures", ["x86_64"])] {
            var f = fields(); f[name] = value; assertThrows(try verify(signed(f)), name)
        }
        assertThrows(try verify(signed(fields()), highWater: 101))
        assertThrows(try verify(signed(fields()), os: "invalid"))
    }
    @Test func testRejectsAttachmentMismatchDowngradeAndStableBeta() throws {
        var f = fields(); f["assetID"] = 99; assertThrows(try verify(signed(f)))
        f = fields(); f["tag"] = "v0.5.3"; f["applicationVersion"] = "0.5.3"
        assertThrows(try verify(signed(f), release: release(f)))
        f["tag"] = "v0.4.0"; f["applicationVersion"] = "0.4.0"; assertThrows(try verify(signed(f), release: release(f)))
        f = fields(); f["tag"] = "v0.6.0-beta.1"; f["applicationVersion"] = "0.6.0-beta.1"; f["channel"] = "beta"
        assertThrows(try verify(signed(f), release: release(f)))
        assertNoThrow(try verify(signed(f), release: release(f), channel: .beta))
    }
    @Test func testExactURLPolicy() {
        for raw in ["http://github.com/a", "https://github.com.evil.test/a", "https://evil.github.com/a",
                    "https://github.com@evil.test/a", "https://github.com:8443/a", "file:///tmp/a"] {
            assertFalse(NetworkPolicy.allowed(URL(string: raw)!))
        }
        assertTrue(NetworkPolicy.allowed(URL(string: "https://release-assets.githubusercontent.com/a?token=opaque")!))
        assertFalse(NetworkPolicy.assetURL(URL(string: "https://github.com/Other/repo/releases/download/v1/file.dmg")!, tag: "v1", name: "file.dmg"))
    }
    private func temporary() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mipad-updater-test-" + UUID().uuidString)
        try PrivateFiles.createDirectory(root)
        temporaryRoots.append(root); return root
    }
    @Test func testStreamedLengthAndDigest() throws {
        let root = try temporary(); let file = root.appendingPathComponent("fixture")
        let bytes = Data(repeating: 0x41, count: 2_097_179); try bytes.write(to: file)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        assertNoThrow(try PackageDigest.verify(file, length: Int64(bytes.count), hash: hash))
        assertThrows(try PackageDigest.verify(file, length: Int64(bytes.count - 1), hash: hash))
        assertThrows(try PackageDigest.verify(file, length: Int64(bytes.count + 1), hash: hash))
        assertThrows(try PackageDigest.verify(file, length: Int64(bytes.count), hash: String(repeating: "0", count: 64)))
    }
    @Test func testPrivateOwnershipAndBundleSymlinks() throws {
        let root = try temporary(); let bundle = root.appendingPathComponent("Fixture.app"); try PrivateFiles.createDirectory(bundle)
        let file = bundle.appendingPathComponent("resource"); try Data("ok".utf8).write(to: file)
        let valid = bundle.appendingPathComponent("internal"); try FileManager.default.createSymbolicLink(atPath: valid.path, withDestinationPath: "resource")
        assertNoThrow(try PrivateFiles.checkBundleLinks(bundle))
        let escaping = bundle.appendingPathComponent("escape"); try FileManager.default.createSymbolicLink(atPath: escaping.path, withDestinationPath: "/etc/hosts")
        assertThrows(try PrivateFiles.checkBundleLinks(bundle))
        assertThrows(try FileIdentity(valid, directory: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        assertThrows(try FileIdentity(root, directory: true, privateOwner: true))
    }
    private func transaction() throws -> (InstallTransaction, URL) {
        let root = try temporary(); let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString); try PrivateFiles.createDirectory(dir)
        let target = root.appendingPathComponent("MiPad2Mac.app"); try PrivateFiles.createDirectory(target)
        try Data("old".utf8).write(to: target.appendingPathComponent("content"))
        let workspace = root.appendingPathComponent(".MiPad2Mac-update-\(id.uuidString)"); try PrivateFiles.createDirectory(workspace)
        let staged = workspace.appendingPathComponent("MiPad2Mac.app"); try PrivateFiles.createDirectory(staged)
        try Data("new".utf8).write(to: staged.appendingPathComponent("content"))
        let candidate = try verify(signed(fields()))
        return (try InstallTransaction(id: id, candidate: candidate, release: release(), channel: .stable,
            source: LaunchSnapshot(version: "0.5.3", build: "24", profile: .developerID, authorizationGeneration: 1, ruleGeneration: 1),
            windowVisible: false, target: target, workspace: workspace, oldProcess: ProcessIdentity(getpid())), dir)
    }
    @Test func testReplacementAndRollbackRetainContents() throws {
        var (t, directory) = try transaction(); try t.validatePaths(directory: directory)
        try Replacement.install(&t)
        assertEqual(String(data: try Data(contentsOf: t.target.appendingPathComponent("content")), encoding: .utf8), "new")
        assertEqual(String(data: try Data(contentsOf: t.backup.appendingPathComponent("content")), encoding: .utf8), "old")
        assertThrows(try Replacement.rollback(&t, newProcessAlive: true))
        try Replacement.rollback(&t, newProcessAlive: false)
        assertEqual(String(data: try Data(contentsOf: t.target.appendingPathComponent("content")), encoding: .utf8), "old")
        assertEqual(t.stage, .rolledBack)
    }
    @Test func testRejectsReplacementAfterObjectChangeOrBackupCollision() throws {
        var (t, _) = try transaction()
        try FileManager.default.moveItem(at: t.target, to: t.target.deletingLastPathComponent().appendingPathComponent("moved.app"))
        try PrivateFiles.createDirectory(t.target)
        assertThrows(try Replacement.install(&t))
        var (other, _) = try transaction(); try PrivateFiles.createDirectory(other.backup)
        assertThrows(try Replacement.install(&other))
    }
    @Test func testReceiptBindsTransactionProcessPathAndVersion() throws {
        var (t, _) = try transaction(); t.launchedProcess = try ProcessIdentity(getpid())
        let update = try verify(signed(fields())).update
        let receipt = InitializationReceipt(transactionID: t.id, process: t.launchedProcess!, target: t.target, version: "0.6.0", build: "25")
        assertTrue(receipt.matches(t, update: update))
        assertFalse(InitializationReceipt(transactionID: UUID(), process: t.launchedProcess!, target: t.target, version: "0.6.0", build: "25").matches(t, update: update))
        assertFalse(InitializationReceipt(transactionID: t.id, process: t.launchedProcess!, target: t.target, version: "0.5.3", build: "24").matches(t, update: update))
    }
    @Test func testPrivateJournalRoundTripAndSignatureRefusal() throws {
        let (t, directory) = try transaction(); let file = directory.appendingPathComponent("transaction.json")
        try PrivateFiles.write(t, to: file)
        assertEqual(try PrivateFiles.read(InstallTransaction.self, from: file).id, t.id)
        assertThrows(try AppValidation.signature(t.target, identifier: UpdateTrust.bundleID))
        assertTrue(try ProcessIdentity(getpid()).isAlive)
    }
    @Test func testSameTargetExclusionAndLockRelease() throws {
        let root = try temporary()
        var first: TargetLock? = try TargetLock(parent: root)
        assertTrue(first != nil)
        assertThrows(try TargetLock(parent: root))
        first = nil
        assertNoThrow(try TargetLock(parent: root))
    }
    @Test func testInterruptedReplacementReconstructsKnownObjects() throws {
        var (t, dir) = try transaction()
        let journal = dir.appendingPathComponent("transaction.json")
        t.stage = .replacing; try PrivateFiles.write(t, to: journal)
        try Replacement.install(&t)
        let interrupted = try PrivateFiles.read(InstallTransaction.self, from: journal)
        assertEqual(try FileIdentity(interrupted.target), interrupted.stagedIdentity)
        assertEqual(try FileIdentity(interrupted.backup), interrupted.targetIdentity)
        // Reconstruct only identities recorded before replacement; preserve anything unknown.
        var restored = interrupted
        restored.installedIdentity = try FileIdentity(restored.target)
        restored.backupIdentity = try FileIdentity(restored.backup)
        try Replacement.rollback(&restored, newProcessAlive: false)
        assertEqual(restored.stage, .rolledBack)
    }
    @Test func testDiskSpaceFailureAndJournalSizeLimit() throws {
        let root = try temporary()
        assertThrows(try PrivateFiles.requireSpace(at: root, bytes: Int64.max))
        let file = root.appendingPathComponent("oversized.json")
        try Data(repeating: 32, count: 131_073).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        assertThrows(try PrivateFiles.read(InstallTransaction.self, from: file))
    }

}
