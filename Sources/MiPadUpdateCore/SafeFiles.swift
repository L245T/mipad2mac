import Foundation
import Darwin

public struct FileIdentity: Codable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public init(_ url: URL, directory: Bool? = nil, privateOwner: Bool = false) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK,
              directory == nil || ((info.st_mode & S_IFMT) == (directory! ? S_IFDIR : S_IFREG)),
              !privateOwner || (info.st_uid == getuid() && info.st_mode & 0o077 == 0) else {
            throw UpdateFailure.rejected("更新路径的类型、所有者或访问权限不安全。")
        }
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino)
    }
}
public enum PrivateFiles {
    public static func validateAncestors(_ url: URL) throws {
        guard url.isFileURL, !url.pathComponents.contains("..") && !url.pathComponents.contains(".") else { throw UpdateFailure.rejected("更新路径格式异常。") }
        var item = url
        while item.path != "/" { _ = try FileIdentity(item); item.deleteLastPathComponent() }
    }
    public static func createDirectory(_ url: URL) throws {
        // Parent has already been validated; mkdir fails on an existing object.
        guard mkdir(url.path, 0o700) == 0 else { throw UpdateFailure.rejected("不能创建私有更新目录。") }
        _ = try FileIdentity(url, directory: true, privateOwner: true)
    }
    public static func root(_ kind: FileManager.SearchPathDirectory, component: String) throws -> URL {
        let base = try FileManager.default.url(for: kind, in: .userDomainMask, appropriateFor: nil, create: true)
        try validateAncestors(base)
        let root = base.appendingPathComponent("org.mipad2mac.app")
        if !FileManager.default.fileExists(atPath: root.path) { try createDirectory(root) }
        _ = try FileIdentity(root, directory: true, privateOwner: true)
        let result = root.appendingPathComponent(component)
        if !FileManager.default.fileExists(atPath: result.path) { try createDirectory(result) }
        _ = try FileIdentity(result, directory: true, privateOwner: true)
        return result
    }
    public static func write<T: Encodable>(_ item: T, to url: URL) throws {
        let data = try JSONEncoder().encode(item)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw UpdateFailure.rejected("不能保护更新记录。") }
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        _ = try FileIdentity(url, directory: false, privateOwner: true)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 131_073) ?? Data()
        guard data.count <= 131_072 else { throw UpdateFailure.rejected("更新记录超过大小上限。") }
        return try JSONDecoder().decode(type, from: data)
    }
    public static func checkBundleLinks(_ root: URL) throws {
        try validateAncestors(root)
        let prefix = try physicalPath(root) + "/"
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
            throw UpdateFailure.rejected("不能读取应用包。")
        }
        for case let item as URL in items {
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                guard try physicalPath(item).hasPrefix(prefix) else {
                    throw UpdateFailure.rejected("应用包含有越界或失效的链接。")
                }
            }
        }
    }
    public static func physicalPath(_ url: URL) throws -> String {
        guard let path = realpath(url.path, nil) else { throw UpdateFailure.rejected("更新路径不能解析。") }
        defer { free(path) }; return String(cString: path)
    }
    public static func requireSpace(at url: URL, bytes: Int64) throws {
        var info = statfs()
        guard statfs(url.path, &info) == 0, info.f_flags & UInt32(MNT_LOCAL) != 0,
              info.f_flags & UInt32(MNT_RDONLY) == 0,
              UInt64(info.f_bavail) * UInt64(info.f_bsize) >= UInt64(max(bytes, 0)) else {
            throw UpdateFailure.rejected("安装位置必须是可写本地磁盘，并有足够可用空间。")
        }
    }
}
public enum SystemCommand {
    public static func run(_ path: String, _ arguments: [String]) throws -> Data {
        // File-backed output avoids pipe deadlocks; command arguments never go through a shell.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.createDirectory(temporary); defer { try? FileManager.default.removeItem(at: temporary) }
        let out = temporary.appendingPathComponent("output")
        FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: out); defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + 120) == .success else {
            process.terminate()
            throw UpdateFailure.rejected("系统校验或复制超时，已停止本次操作。")
        }
        guard process.terminationStatus == 0 else { throw UpdateFailure.rejected("系统校验或复制失败（\(URL(fileURLWithPath: path).lastPathComponent)）。") }
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64 ?? 0
        guard size <= 1_048_576 else { throw UpdateFailure.rejected("系统返回超出读取上限。") }
        return try Data(contentsOf: out)
    }
}

public final class TargetLock {
    private var fd: Int32 = -1
    public init(parent: URL) throws {
        try PrivateFiles.validateAncestors(parent)
        let path = parent.appendingPathComponent(".MiPad2Mac-update.lock")
        fd = open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw UpdateFailure.rejected("不能锁定安装位置。") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, (info.st_mode & S_IFMT) == S_IFREG, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); fd = -1; throw UpdateFailure.rejected("该安装位置正被占用或锁文件不安全。")
        }
    }
    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}
