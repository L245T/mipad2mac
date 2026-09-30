import Foundation
import Security
import Darwin

public enum AppValidation {
    public static let publisher = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"4R6JZ29FML\""
    public static func requirement(identifier: String) throws -> SecRequirement {
        var value: SecRequirement?
        guard SecRequirementCreateWithString(("identifier \"\(identifier)\" and " + publisher) as CFString, [], &value) == errSecSuccess,
              let value else { throw UpdateFailure.rejected("不能建立发行身份校验。") }; return value
    }
    public static func signature(_ url: URL, identifier: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), try requirement(identifier: identifier)) == errSecSuccess else {
            throw UpdateFailure.rejected("应用完整性或指定发行者签名未通过验证。")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let flags = values[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0,
              values[kSecCodeInfoTimestamp as String] is Date else {
            throw UpdateFailure.rejected("正式更新要求Hardened Runtime及安全时间戳。")
        }
    }
    public static func gatekeeper(_ url: URL) throws {
        _ = try SystemCommand.run("/usr/sbin/spctl", ["--assess", "--type", "execute", url.path])
    }
    public static func process(_ pid: Int32, executable: URL, identifier: String) throws {
        guard try ProcessIdentity(pid).executable == executable.path else { throw UpdateFailure.rejected("运行进程路径不匹配。") }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], try requirement(identifier: identifier)) == errSecSuccess else {
            throw UpdateFailure.rejected("运行进程发行身份不匹配。")
        }
    }
    public static func metadata(_ url: URL) throws -> [String: Any] {
        _ = try FileIdentity(url, directory: true)
        let plist = url.appendingPathComponent("Contents/Info.plist")
        _ = try FileIdentity(plist, directory: false)
        let handle = try FileHandle(forReadingFrom: plist); defer { try? handle.close() }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536, let p = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              p["CFBundleIdentifier"] as? String == UpdateTrust.bundleID,
              p["CFBundleExecutable"] as? String == "MiPad2Mac" else { throw UpdateFailure.rejected("应用元数据不匹配。") }; return p
    }
    public static func app(_ url: URL, update: SignedUpdate) throws {
        try PrivateFiles.checkBundleLinks(url)
        try signature(url, identifier: UpdateTrust.bundleID)
        let p = try metadata(url)
        guard p["CFBundleShortVersionString"] as? String == update.applicationVersion,
              p["CFBundleVersion"] as? String == update.buildNumber,
              let minimum = p["LSMinimumSystemVersion"] as? String,
              OSVersion(minimum) == OSVersion(update.minimumOS) else { throw UpdateFailure.rejected("安装包版本或系统要求与清单不匹配。") }
        let binary = url.appendingPathComponent("Contents/MacOS/MiPad2Mac")
        let architectures = try SystemCommand.run("/usr/bin/lipo", ["-archs", binary.path])
        guard let text = String(data: architectures, encoding: .utf8),
              Set(text.split(whereSeparator: { $0.isWhitespace }).map(String.init)) == Set(update.architectures) else {
            throw UpdateFailure.rejected("应用架构与清单不匹配。")
        }
        try signature(url.appendingPathComponent("Contents/MacOS/MiPad2MacUpdater"), identifier: "org.mipad2mac.updater")
    }
}
public struct ProcessIdentity: Codable, Equatable {
    public let pid: Int32
    public let startedSeconds: Int64
    public let startedMicroseconds: Int32
    public let executable: String
    public init(_ pid: Int32) throws {
        var info = kinfo_proc(); var length = MemoryLayout<kinfo_proc>.size
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard sysctl(&query, u_int(query.count), &info, &length, nil, 0) == 0, length > 0,
              info.kp_eproc.e_ucred.cr_uid == getuid(), proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            throw UpdateFailure.rejected("进程不存在或不属于当前用户。")
        }
        self.pid = pid; startedSeconds = Int64(info.kp_proc.p_starttime.tv_sec)
        startedMicroseconds = Int32(info.kp_proc.p_starttime.tv_usec); executable = String(cString: path)
    }
    public var isAlive: Bool { (try? Self(pid)) == self }
}
