import Foundation
import Testing
@testable import MiPadCore

struct ReleaseVersionTests {
    @Test func numericOrdering() {
        #expect(ReleaseVersion("0.1.9")! < ReleaseVersion("v0.1.12")!)
        #expect(ReleaseVersion("0.9.99")! < ReleaseVersion("1.0.0")!)
        #expect(ReleaseVersion("v0.1.12") == ReleaseVersion("0.1.12"))
    }
    @Test func malformedAndPrereleaseRejected() {
        for value in ["", "1.2", "1.2.3.4", "1.2.3-beta", "-1.2.3", "01.2.3", "1. 2.3", "1.2.999999999999999999999999"] {
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
