import Foundation
import Testing
@testable import MiPadCore

struct MigrationNoticeTests {
    func snapshot(_ version: String = "0.7.0", _ profile: ReleaseProfile = .developerID, generation: Int = 1) -> LaunchSnapshot {
        LaunchSnapshot(version: version, build: "24", profile: profile, authorizationGeneration: generation, ruleGeneration: 1)
    }
    func rule(_ id: String = "identity", introduced: String? = "0.6.0-beta.1", generation: Int = 1, supersedes: Set<String> = []) -> MigrationRule {
        MigrationRule(id: id, introducedIn: introduced, sourceProfiles: [.localDevelopment, .developerID], targetProfile: .developerID,
                      targetGeneration: generation, cause: "test", capabilities: [.control], explainUnknownSource: true, supersedes: supersedes)
    }
    @Test func knownJumpAndSameVersionIdentity() {
        for version in ["0.5.3", "0.7.0"] {
            var h = MigrationHistory(); h.lastSuccessfulLaunch = snapshot(version, .localDevelopment, generation: 0)
            let selected = MigrationNotices.prepare(current: snapshot(), history: &h, rules: [rule()])
            #expect(selected.count == 1 && !selected[0].unknownSource)
            #expect(h.lastSuccessfulLaunch == snapshot())
        }
    }
    @Test func unknownFreshCorruptAndInvalidSourceStayConditional() {
        for data in [nil, Data("bad".utf8)] as [Data?] {
            var h = MigrationHistory.decode(data)
            #expect(MigrationNotices.prepare(current: snapshot(), history: &h, rules: [rule()]).first?.unknownSource == true)
        }
        var h = MigrationHistory(); h.lastSuccessfulLaunch = snapshot("invalid")
        #expect(MigrationNotices.prepare(current: snapshot(), history: &h, rules: [rule()]).first?.unknownSource == true)
    }
    @Test func pendingSurvivesNewLaunchAndCrashAndPersistence() throws {
        var h = MigrationHistory(); h.lastSuccessfulLaunch = snapshot("0.5.3", .localDevelopment, generation: 0)
        _ = MigrationNotices.prepare(current: snapshot(), history: &h, rules: [rule()])
        var restored = MigrationHistory.decode(try JSONEncoder().encode(h))
        let selected = MigrationNotices.prepare(current: snapshot("0.8.0"), history: &restored, rules: [rule()])
        #expect(selected.count == 1 && !selected[0].unknownSource)
        MigrationNotices.acknowledge(selected, history: &restored)
        #expect(restored.pending.isEmpty)
        #expect(MigrationNotices.prepare(current: snapshot("0.9.0"), history: &restored, rules: [rule()]).isEmpty)
    }
    @Test func betaStableDowngradeAndRevocationDoNotRepeatAcknowledgement() {
        var h = MigrationHistory()
        let selected = MigrationNotices.prepare(current: snapshot("0.6.0-beta.2"), history: &h, rules: [rule()])
        MigrationNotices.acknowledge(selected, history: &h)
        for version in ["0.6.0", "0.5.3", "0.8.0"] {
            #expect(MigrationNotices.prepare(current: snapshot(version), history: &h, rules: [rule()]).isEmpty)
        }
        #expect(h.acknowledged.count == 1)
    }
    @Test func inactiveFutureAndWrongIdentityRulesDoNotTrigger() {
        var h = MigrationHistory()
        #expect(MigrationNotices.prepare(current: snapshot(), history: &h, rules: [rule(introduced: nil)]).isEmpty)
        #expect(MigrationNotices.prepare(current: snapshot(), history: &h, rules: [rule(introduced: "0.8.0")]).isEmpty)
        #expect(MigrationNotices.prepare(current: snapshot("0.7.0", .localDevelopment), history: &h, rules: [rule()]).isEmpty)
    }
    @Test func combineSupersedeAndNewGeneration() {
        var h = MigrationHistory()
        let selected = MigrationNotices.prepare(current: snapshot(generation: 2), history: &h,
            rules: [rule("old", generation: 2), rule("new", generation: 2, supersedes: ["old"]), rule("independent", generation: 2)])
        #expect(selected.map(\.rule.id) == ["new", "independent"])
        MigrationNotices.acknowledge(selected, history: &h)
        #expect(h.pending.isEmpty)
        #expect(MigrationNotices.prepare(current: snapshot(generation: 2), history: &h, rules: [rule("old", generation: 2)]).isEmpty)
        #expect(MigrationNotices.prepare(current: snapshot(generation: 3), history: &h, rules: [rule("next", generation: 3)]).count == 1)
    }
    @Test func updaterSourceOverridesSuccessfulLaunchOnlyWhenSuppliedByCaller() {
        var h = MigrationHistory(); h.lastSuccessfulLaunch = snapshot()
        let selected = MigrationNotices.prepare(current: snapshot(), trustedSource: snapshot("0.5.3", .localDevelopment, generation: 0), history: &h, rules: [rule()])
        #expect(selected.count == 1 && !selected[0].unknownSource)
    }
}
