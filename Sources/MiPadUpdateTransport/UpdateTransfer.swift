import Foundation
import Darwin
import MiPadUpdateCore

/// One transfer per user action. Delegate callbacks are serialized; UI changes run on main.
public final class UpdateTransfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate {
    var testProtocols: [AnyClass]?
    private var session: URLSession!
    private var task: URLSessionTask?
    private var body = Data()
    private let limit: Int64
    private let destination: URL?
    private var completed = false
    private var lastProgress = -Double.infinity
    public var progress: (Double) -> Void = { _ in }
    public var result: (Result<Data, Error>) -> Void = { _ in }
    public init(limit: Int64, destination: URL? = nil) { self.limit = limit; self.destination = destination; super.init() }
    public func start(_ url: URL) {
        guard NetworkPolicy.allowed(url) else { result(.failure(UpdateFailure.rejected("下载地址不在允许范围内。"))); return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 900
        config.protocolClasses = testProtocols
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url); request.setValue("MiPad2Mac", forHTTPHeaderField: "User-Agent")
        task = destination == nil ? session.dataTask(with: request) : session.downloadTask(with: request)
        task?.resume()
    }
    public func cancel() { task?.cancel() }
    private func finish(_ value: Result<Data, Error>) {
        guard !completed else { return }; completed = true
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async { self.result(value) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url.map(NetworkPolicy.allowed) == true
        completionHandler(allowed ? request : nil)
        if !allowed { task.cancel(); finish(.failure(UpdateFailure.rejected("下载跳转地址不在允许范围内。"))) }
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let valid = (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= limit &&
                    response.url.map(NetworkPolicy.allowed) == true
        completionHandler(valid ? .allow : .cancel)
        if !valid { finish(.failure(UpdateFailure.rejected("清单响应异常或超过大小上限。"))) }
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard Int64(body.count) + Int64(data.count) <= limit else {
            dataTask.cancel(); finish(.failure(UpdateFailure.rejected("清单超过大小上限。"))); return
        }
        body.append(data)
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit,
              (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            downloadTask.cancel(); finish(.failure(UpdateFailure.rejected("下载文件超过大小上限或响应异常。"))); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgress >= 0.2 { lastProgress = now; let value = Double(totalBytesWritten) / Double(limit)
            DispatchQueue.main.async { self.progress(min(value, 1)) }
        }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !completed else { return }
        do {
            guard let destination, let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  response.url.map(NetworkPolicy.allowed) == true else { throw UpdateFailure.rejected("下载响应异常。") }
            let attrs = try FileManager.default.attributesOfItem(atPath: location.path)
            guard let length = attrs[.size] as? Int64, length <= limit else { throw UpdateFailure.rejected("下载文件超过大小上限。") }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            // Mark remote material as quarantined; never clear an existing download quarantine.
            let quarantine = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";MiPad2Mac;" + UUID().uuidString
            guard quarantine.withCString({ setxattr(destination.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }) == 0 else {
                throw UpdateFailure.rejected("不能保留下载隔离属性。")
            }
            finish(.success(Data()))
        } catch { finish(.failure(error)) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if destination == nil { finish(.success(body)) }
    }
}
