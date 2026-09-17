import Foundation

/// SemVer precedence; optional v prefix, build metadata does not affect ordering.
public struct ReleaseVersion: Comparable {
    public let parts: [Int]
    public let prerelease: [String]
    public init?(_ value: String) {
        var text = value
        if text.hasPrefix("v") { text.removeFirst() }
        let build = text.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2 else { return nil }
        func identifiers(_ value: Substring) -> [String]? {
            let fields = value.split(separator: ".", omittingEmptySubsequences: false)
            guard fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            } }) else { return nil }
            return fields.map(String.init)
        }
        if build.count == 2, identifiers(build[1]) == nil { return nil }
        let version = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let fields = version[0].split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        var values: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }),
                  field.count == 1 || !field.hasPrefix("0"), let n = Int(field) else { return nil }
            values.append(n)
        }
        var suffix: [String] = []
        if version.count == 2 {
            guard let ids = identifiers(version[1]), ids.allSatisfy({
                !$0.utf8.allSatisfy({ (48...57).contains($0) }) || $0.count == 1 || !$0.hasPrefix("0")
            }) else { return nil }
            suffix = ids
        }
        parts = values; prerelease = suffix
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.parts != rhs.parts { return lhs.parts.lexicographicallyPrecedes(rhs.parts) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let ln = left.utf8.allSatisfy { (48...57).contains($0) }
            let rn = right.utf8.allSatisfy { (48...57).contains($0) }
            if ln != rn { return ln }
            if ln && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public enum UpdateChannel: String, CaseIterable {
    case stable, beta
    public var title: String { self == .stable ? "稳定版" : "Beta 版" }
}

public struct PublishedRelease: Decodable {
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public var isPrerelease: Bool { prerelease || !(ReleaseVersion(tag_name)?.prerelease.isEmpty ?? true) }
    public func isEligible(for channel: UpdateChannel) -> Bool {
        !draft && ReleaseVersion(tag_name) != nil && (channel == .beta || !isPrerelease)
    }
    public func isNewer(than current: String, channel: UpdateChannel = .stable) -> Bool {
        guard isEligible(for: channel), let remote = ReleaseVersion(tag_name), let local = ReleaseVersion(current) else { return false }
        return remote > local
    }
    public static func latest(in releases: [Self], channel: UpdateChannel) -> Self? {
        releases.filter { $0.isEligible(for: channel) }.max {
            let left = ReleaseVersion($0.tag_name)!, right = ReleaseVersion($1.tag_name)!
            if left != right { return left < right }
            // Prefer a stable publication when equivalent tags have equal precedence.
            if $0.isPrerelease != $1.isPrerelease { return $0.isPrerelease }
            return $0.tag_name < $1.tag_name
        }
    }
    public var downloadURL: URL? {
        guard ReleaseVersion(tag_name) != nil else { return nil }
        var url = URLComponents(string: "https://github.com/L245T/mipad2mac")!
        url.path = "/L245T/mipad2mac/releases/tag/" + tag_name
        return url.url
    }
}
