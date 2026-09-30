import Foundation
import Testing
@testable import MiPadUpdateTransport

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/cancel" { return }
        let status = url.path == "/failure" ? 503 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fixture-data".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
struct TransferTests {
    private func transfer(path: String, limit: Int64, cancel: Bool = false) async -> Result<Data, Error> {
        await withCheckedContinuation { continuation in
            let request = UpdateTransfer(limit: limit); request.testProtocols = [FixtureProtocol.self]
            request.result = { result in continuation.resume(returning: result) }
            request.start(URL(string: "https://github.com\(path)")!)
            if cancel { request.cancel() }
        }
    }
    @Test func boundedTransferSuccessAndNetworkFailure() async throws {
        #expect(try await transfer(path: "/ok", limit: 64).get() == Data("fixture-data".utf8))
        let failure = await transfer(path: "/failure", limit: 64)
        if case .success = failure { Issue.record("Non-200 response accepted") }
    }
    @Test func oversizedBodyAndCancellationFailClosed() async {
        for result in [await transfer(path: "/large", limit: 3), await transfer(path: "/cancel", limit: 64, cancel: true)] {
            if case .success = result { Issue.record("Cancelled or oversized transfer accepted") }
        }
    }
}
