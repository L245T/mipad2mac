import Foundation
import Testing
@testable import MiPadCore

struct ReleaseVersionTests {
    @Test func numericOrdering() {
        #expect(ReleaseVersion("0.1.9")! < ReleaseVersion("v0.1.12")!)
        #expect(ReleaseVersion("0.9.99")! < ReleaseVersion("1.0.0")!)
        #expect(ReleaseVersion("v0.1.12") == ReleaseVersion("0.1.12"))
    }
    @Test func malformedVersionsRejected() {
        for value in ["", "1.2", "1.2.3.4", "1.2.3-", "1.2.3-beta..1", "1.2.3-beta.01", "1.2.3+", "1.2.3+build+again", "1.2.3-测试", "-1.2.3", "01.2.3", "1. 2.3", "1.2.999999999999999999999999"] {
            #expect(ReleaseVersion(value) == nil)
        }
    }
    @Test func onlyPublishedNewerReleases() throws {
        for (tag, draft, prerelease, expected) in [("v0.1.13", false, false, true), ("v0.1.12", false, false, false), ("v0.1.11", false, false, false), ("v0.1.13", true, false, false), ("v0.1.13", false, true, false), ("garbage", false, false, false)] {
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease])
            let release = try JSONDecoder().decode(PublishedRelease.self, from: data)
            #expect(release.isNewer(than: "0.1.12") == expected)
        }
    }
}

struct UpdateChannelTests {
    private func release(_ tag: String, beta: Bool = false, draft: Bool = false) throws -> PublishedRelease {
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": beta])
        return try JSONDecoder().decode(PublishedRelease.self, from: data)
    }
    @Test func semverPrereleaseOrdering() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for (a, b) in zip(ordered, ordered.dropFirst()) { #expect(ReleaseVersion(a)! < ReleaseVersion(b)!) }
        #expect(ReleaseVersion("v1.2.3+build.01") == ReleaseVersion("1.2.3+other"))
        #expect(ReleaseVersion("1.0.0-beta.999999999999999999999")! < ReleaseVersion("1.0.0-beta.1000000000000000000000")!)
    }
    @Test func filtersDraftsAndBothKindsOfPrerelease() throws {
        let releases = try [release("v0.4.0"), release("v0.5.0", beta: true), release("v0.6.0-beta.1"), release("v9.0.0", draft: true), release("bad")]
        #expect(PublishedRelease.latest(in: releases, channel: .stable)?.tag_name == "v0.4.0")
        #expect(PublishedRelease.latest(in: releases, channel: .beta)?.tag_name == "v0.6.0-beta.1")
    }
    @Test func betaAlsoReceivesStableAndDoesNotRelyOnAPIOrder() throws {
        let releases = try [release("1.0.0-beta.2", beta: true), release("0.9.0"), release("1.0.0"), release("1.0.0-beta.11", beta: true)]
        #expect(PublishedRelease.latest(in: releases, channel: .beta)?.tag_name == "1.0.0")
        #expect(try release("1.0.0").isNewer(than: "1.0.0-beta.11", channel: .beta))
    }
    @Test func noDowngradeAndNoSameVersionRebuildUpdate() throws {
        #expect(try !release("0.4.0-beta.1", beta: true).isNewer(than: "0.4.0", channel: .beta))
        #expect(try !release("0.3.1", beta: true).isNewer(than: "0.3.1", channel: .beta))
        #expect(try !release("0.3.0").isNewer(than: "0.4.0-beta.1"))
        #expect(try !release("1.0.0").isNewer(than: "75d4cfb1c5c8", channel: .beta))
    }
    @Test func emptyOrIneligibleChannelHasNoCandidate() throws {
        #expect(PublishedRelease.latest(in: [], channel: .beta) == nil)
        #expect(try PublishedRelease.latest(in: [release("0.4.0", beta: true)], channel: .stable) == nil)
        #expect(try PublishedRelease.latest(in: [release("0.4.0", draft: true), release("unknown")], channel: .beta) == nil)
    }
    @Test func downloadTargetsSelectedTag() throws {
        #expect(try release("v0.4.0-beta.2", beta: true).downloadURL?.absoluteString == "https://github.com/L245T/mipad2mac/releases/tag/v0.4.0-beta.2")
        #expect(try release("https://evil.example").downloadURL == nil)
    }
    @Test func equivalentVersionsPreferStablePublication() throws {
        let releases = try [release("v1.0.0", beta: true), release("1.0.0")]
        #expect(PublishedRelease.latest(in: releases, channel: .beta)?.prerelease == false)
    }
}
