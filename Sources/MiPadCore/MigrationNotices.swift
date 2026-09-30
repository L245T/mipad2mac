import Foundation

public enum ReleaseProfile: String, Codable { case unknown, localDevelopment, developerID }
public struct LaunchSnapshot: Codable, Equatable {
    public let version: String
    public let build: String
    public let profile: ReleaseProfile
    public let authorizationGeneration: Int
    public let ruleGeneration: Int
    public init(version: String, build: String, profile: ReleaseProfile, authorizationGeneration: Int, ruleGeneration: Int) {
        self.version = version; self.build = build; self.profile = profile
        self.authorizationGeneration = authorizationGeneration; self.ruleGeneration = ruleGeneration
    }
    public var valid: Bool {
        ReleaseVersion(version) != nil && !build.isEmpty && build.allSatisfy(\.isNumber) &&
        authorizationGeneration >= 0 && ruleGeneration >= 0
    }
}
public enum PermissionCapability: String, Codable, CaseIterable { case control, postEvents, inputMonitoring }
public enum PermissionState: String { case granted, denied, unknown }
public struct MigrationRule {
    public let id: String
    /// nil keeps a prepared rule inactive until its first real release is chosen.
    public let introducedIn: String?
    public let sourceProfiles: Set<ReleaseProfile>
    public let targetProfile: ReleaseProfile
    public let targetGeneration: Int
    public let cause: String
    public let capabilities: [PermissionCapability]
    public let explainUnknownSource: Bool
    public let supersedes: Set<String>
    public init(id: String, introducedIn: String?, sourceProfiles: Set<ReleaseProfile>, targetProfile: ReleaseProfile,
                targetGeneration: Int, cause: String, capabilities: [PermissionCapability], explainUnknownSource: Bool,
                supersedes: Set<String> = []) {
        self.id = id; self.introducedIn = introducedIn; self.sourceProfiles = sourceProfiles
        self.targetProfile = targetProfile; self.targetGeneration = targetGeneration; self.cause = cause
        self.capabilities = capabilities; self.explainUnknownSource = explainUnknownSource; self.supersedes = supersedes
    }
    public var key: String { "\(id)|\(targetProfile.rawValue)|\(targetGeneration)" }
}
public struct PendingMigrationNotice: Codable, Equatable {
    public let key: String
    public let unknownSource: Bool
    public init(key: String, unknownSource: Bool) { self.key = key; self.unknownSource = unknownSource }
}
public struct MigrationHistory: Codable, Equatable {
    public var schema = 1
    public var lastSuccessfulLaunch: LaunchSnapshot?
    public var acknowledged: Set<String> = []
    public var pending: [PendingMigrationNotice] = []
    public init() {}
    public static func decode(_ data: Data?) -> Self {
        guard let data, let history = try? JSONDecoder().decode(Self.self, from: data), history.schema == 1 else { return Self() }
        var result = history
        if result.lastSuccessfulLaunch?.valid == false { result.lastSuccessfulLaunch = nil }
        return result
    }
}
public struct MigrationSelection {
    public let rule: MigrationRule
    public let unknownSource: Bool
    public var coveredKeys: Set<String> = []
}
public enum MigrationNotices {
    /// Reads the previous launch before updating it. Pending and acknowledgement survive ordinary upgrades/downgrades.
    public static func prepare(current: LaunchSnapshot, trustedSource: LaunchSnapshot? = nil,
                               history: inout MigrationHistory, rules: [MigrationRule]) -> [MigrationSelection] {
        let old = trustedSource ?? history.lastSuccessfulLaunch
        let source = old?.valid == true && old?.profile != .unknown ? old : nil
        guard current.valid, let version = ReleaseVersion(current.version) else { return [] }
        var selected: [MigrationSelection] = []
        for rule in rules {
            guard let introduced = rule.introducedIn.flatMap(ReleaseVersion.init), version >= introduced,
                  current.profile == rule.targetProfile, current.authorizationGeneration >= rule.targetGeneration,
                  !history.acknowledged.contains(rule.key) else { continue }
            let pending = history.pending.first { $0.key == rule.key }
            let applicable: Bool
            if let source {
                applicable = rule.sourceProfiles.contains(source.profile) &&
                    (source.profile != rule.targetProfile || source.authorizationGeneration < rule.targetGeneration)
            } else { applicable = rule.explainUnknownSource }
            guard applicable || pending != nil else { continue }
            let unknown = pending?.unknownSource ?? (source == nil)
            if pending == nil { history.pending.append(PendingMigrationNotice(key: rule.key, unknownSource: unknown)) }
            selected.append(MigrationSelection(rule: rule, unknownSource: unknown))
        }
        let replaced = selected.reduce(into: Set<String>()) { $0.formUnion($1.rule.supersedes) }
        selected.removeAll { replaced.contains($0.rule.id) }
        for index in selected.indices {
            let replacement = selected[index].rule
            selected[index].coveredKeys = Set(rules.filter {
                replacement.supersedes.contains($0.id) && $0.targetProfile == replacement.targetProfile &&
                $0.targetGeneration <= replacement.targetGeneration
            }.map(\.key))
        }
        history.lastSuccessfulLaunch = current
        return selected
    }
    public static func acknowledge(_ selected: [MigrationSelection], history: inout MigrationHistory) {
        for item in selected {
            history.acknowledged.insert(item.rule.key)
            history.acknowledged.formUnion(item.coveredKeys)
        }
        history.pending.removeAll { history.acknowledged.contains($0.key) }
    }
}
