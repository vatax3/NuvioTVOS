import Foundation
@testable import Nuvio

/// Answers requests from a script instead of the network.
///
/// It exists because the endpoints under test *mutate somebody's library*. There is no way to
/// exercise `sync/watchlist` or `sync/history` against a live Trakt account without adding and
/// removing real titles from it, so the tests must never reach one.
final class StubURLProtocol: URLProtocol {
    struct Exchange {
        var status: Int = 200
        var body: Data = Data("{}".utf8)
    }

    /// Recorded so a test can assert on the path, the method, the auth headers and the body —
    /// the parts a status code says nothing about.
    struct RecordedRequest {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?

        var json: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: ((URLRequest) -> Exchange)?
    nonisolated(unsafe) private static var recorded: [RecordedRequest] = []

    static var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Installs a session that answers through this protocol, and hands back the teardown.
    static func install(_ responder: @escaping (URLRequest) -> Exchange) -> () -> Void {
        lock.lock()
        self.responder = responder
        recorded = []
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let previous = IntegrationHTTP.session
        IntegrationHTTP.session = URLSession(configuration: configuration)
        return {
            IntegrationHTTP.session = previous
            lock.lock()
            self.responder = nil
            recorded = []
            lock.unlock()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips the body into a stream, so it has to be read back to be asserted on.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            var buffer = [UInt8](repeating: 0, count: size)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        }

        Self.lock.lock()
        Self.recorded.append(
            RecordedRequest(
                method: request.httpMethod ?? "GET",
                url: request.url!,
                headers: request.allHTTPHeaderFields ?? [:],
                body: body
            )
        )
        let exchange = Self.responder?(request) ?? Exchange()
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: exchange.status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: exchange.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
