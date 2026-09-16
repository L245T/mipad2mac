import Foundation

public struct ReleaseVersion: Comparable {
    public let parts: [Int]
    public init?(_ value: String) {
        var text = value
        if text.hasPrefix("v") { text.removeFirst() }
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        var values: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }),
                  field.count == 1 || !field.hasPrefix("0"), let n = Int(field) else { return nil }
            values.append(n)
        }
        parts = values
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

public struct PublishedRelease: Decodable {
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public func isNewer(than current: String) -> Bool {
        guard !draft, !prerelease, let remote = ReleaseVersion(tag_name), let local = ReleaseVersion(current) else { return false }
        return remote > local
    }
}
