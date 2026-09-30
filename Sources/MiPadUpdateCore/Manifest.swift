import Foundation
import CryptoKit
import MiPadCore

public enum UpdateFailure: Error, LocalizedError {
    case rejected(String)
    public var errorDescription: String? { if case .rejected(let reason) = self { return reason }; return nil }
}
public struct SignedUpdate: Codable, Equatable {
    public let schemaVersion: Int
    public let repository: String
    public let releaseID: Int
    public let tag: String
    public let applicationVersion: String
    public let buildNumber: String
    public let channel: String
    public let bundleIdentifier: String
    public let assetID: Int
    public let assetName: String
    public let byteLength: Int64
    public let sha256: String
    public let minimumOS: String
    public let architectures: [String]
    public let installerProtocol: Int
    public let publicationSequence: Int64
    public let targetIdentityProfile: String
}
public struct ManifestEnvelope: Codable {
    public let payloadBase64: String
    public let signatureBase64: String
    public let keyID: String
    public init(payloadBase64: String, signatureBase64: String, keyID: String) {
        self.payloadBase64 = payloadBase64; self.signatureBase64 = signatureBase64; self.keyID = keyID
    }
}
public struct TrustedCandidate {
    public let update: SignedUpdate
    public let asset: ReleaseAsset
    public let envelope: Data
}
public enum UpdateTrust {
    public static let repository = "L245T/mipad2mac"
    public static let bundleID = "org.mipad2mac.app"
    public static let publisherProfile = "developer-id-v1"
    // Deliberately empty until a reviewed distribution public key is provisioned.
    // Test keys are injected by tests only. No network response can add trust.
    public static let productionKeys: [String: Data] = [:]
    public static let maximumPackageBytes: Int64 = 1_073_741_824
    public static func decode(_ data: Data, keys: [String: Data]) throws -> SignedUpdate {
        guard data.count <= 65_536 else { throw UpdateFailure.rejected("更新清单超过大小上限。") }
        let e = try JSONDecoder().decode(ManifestEnvelope.self, from: data)
        guard let rawKey = keys[e.keyID], rawKey.count == 32,
              let payload = Data(base64Encoded: e.payloadBase64), payload.count <= 32_768,
              let signature = Data(base64Encoded: e.signatureBase64), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              key.isValidSignature(signature, for: payload) else {
            throw UpdateFailure.rejected("更新清单的发布签名未通过验证。")
        }
        return try JSONDecoder().decode(SignedUpdate.self, from: payload)
    }
    public static func candidate(_ data: Data, release: PublishedRelease, channel: UpdateChannel,
                                 currentVersion: String, highWater: Int64, osVersion: String, architecture: String,
                                 keys: [String: Data] = productionKeys) throws -> TrustedCandidate {
        let m = try decode(data, keys: keys)
        guard m.schemaVersion == 1, m.installerProtocol == 1, m.repository == repository,
              m.bundleIdentifier == bundleID, m.targetIdentityProfile == publisherProfile,
              m.publicationSequence > 0, m.publicationSequence >= highWater,
              m.releaseID > 0, m.assetID > 0, release.id == m.releaseID, release.tag_name == m.tag,
              ReleaseVersion(m.applicationVersion) == ReleaseVersion(m.tag),
              release.isNewer(than: currentVersion, channel: channel),
              m.channel == (release.isPrerelease ? "beta" : "stable"),
              let minimum = OSVersion(m.minimumOS), let current = OSVersion(osVersion), current >= minimum,
              !m.architectures.isEmpty, Set(m.architectures).isSubset(of: ["arm64", "x86_64"]),
              m.architectures.contains(architecture),
              !m.buildNumber.isEmpty, m.buildNumber.utf8.allSatisfy({ (48...57).contains($0) }),
              m.byteLength > 0, m.byteLength <= maximumPackageBytes,
              m.sha256.count == 64, m.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              m.assetName.hasPrefix("MiPad2Mac-"), m.assetName.hasSuffix(".dmg"),
              !m.assetName.contains("/"), !m.assetName.contains("\\"),
              let asset = release.assets?.first(where: { $0.id == m.assetID && $0.name == m.assetName && $0.size == m.byteLength }),
              release.assets?.filter({ $0.id == m.assetID }).count == 1,
              NetworkPolicy.assetURL(asset.browser_download_url, tag: m.tag, name: m.assetName) else {
            throw UpdateFailure.rejected("更新清单与版本、附件或当前系统不匹配；请使用发布页面手动安装。")
        }
        return TrustedCandidate(update: m, asset: asset, envelope: data)
    }
}
public struct OSVersion: Comparable {
    let parts: [Int]
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        self.parts = parts.map { Int($0)! } + Array(repeating: 0, count: 3 - parts.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}
public enum NetworkPolicy {
    public static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host)
    }
    public static func assetURL(_ url: URL, tag: String, name: String) -> Bool {
        allowed(url) && url.host == "github.com" && url.query == nil && url.fragment == nil &&
        url.path == "/L245T/mipad2mac/releases/download/\(tag)/\(name)"
    }
}
public enum PackageDigest {
    public static func verify(_ url: URL, length: Int64, hash: String) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256(); var total: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            total += Int64(data.count)
            guard total <= length else { throw UpdateFailure.rejected("下载文件超过清单中的大小。") }
            digest.update(data: data)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == length, actual == hash else { throw UpdateFailure.rejected("下载文件的长度或SHA-256不匹配。") }
    }
}
