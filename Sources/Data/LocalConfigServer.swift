import Foundation
import Network
import Observation
import OSLog

/// A one-page HTTP server the television runs so a phone on the same network can type into it.
///
/// tvOS has no web view and no keyboard worth the name. Android solves the same problem the same
/// way — `core/server/` there is four of these — and it is the only way to offer an editor for
/// something like a stream-name template, which is a line of expression syntax nobody is going
/// to enter on a remote control.
///
/// Deliberately minimal, and deliberately not a general web server. It binds to the local
/// network, serves exactly one page, accepts exactly one form post, and stops when the screen
/// that started it goes away. It has no routing table to get wrong and nothing to serve that it
/// was not handed.
@MainActor
@Observable
final class LocalConfigServer {
    /// Where a phone should point, once the listener is up.
    private(set) var address: String?
    private(set) var failure: String?

    /// Bumped whenever a post lands, so the screen showing the QR can reflect the new values
    /// without polling.
    private(set) var revision = 0

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: NWConnection] = [:]
    @ObservationIgnored private var page: () -> String = { "" }
    @ObservationIgnored private var handler: ([String: String]) async -> Void = { _ in }
    @ObservationIgnored private let log = Logger(subsystem: "com.nuvio.tvos", category: "ConfigServer")

    /// Starts serving, replacing anything already running.
    ///
    /// - Parameters:
    ///   - page: builds the HTML on each request, so the form always shows the current values
    ///     rather than the ones captured when the screen opened.
    ///   - onSubmit: the decoded form fields. Awaited before the redirect goes out, so a
    ///     submission that has to reach the network — importing a badge pack from a URL — sends
    ///     the phone back to a page that already reflects what it did.
    func start(page: @escaping () -> String, onSubmit: @escaping ([String: String]) async -> Void) {
        stop()
        self.page = page
        self.handler = onSubmit

        do {
            // Port 0 lets the system pick a free one, so a stale listener from a previous screen
            // can never make this fail with "address in use".
            let listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.apply(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            failure = error.localizedDescription
            log.error("listener failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        address = nil
        failure = nil
    }

    private func apply(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            guard let host = LocalNetworkAddress.current() else {
                failure = "This Apple TV has no address on the local network."
                return
            }
            address = "http://\(host):\(port)"
        case .failed(let error):
            failure = error.localizedDescription
            log.error("listener failed: \(error.localizedDescription, privacy: .public)")
        case .cancelled:
            address = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    /// A request arrives in as many pieces as the network feels like. Headers tell us how much
    /// body to expect, so the read continues until the whole of it is in hand — a form posted
    /// from a phone is small, but it is not guaranteed to be one packet.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil else { return self.close(connection) }

                var buffer = buffer
                if let data { buffer.append(data) }

                guard let request = HTTPRequest(buffer) else {
                    if isComplete { self.close(connection) } else { self.receive(connection, buffer: buffer) }
                    return
                }
                await self.respond(to: request, on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        if request.method == "POST" {
            await handler(FormDecoder.decode(request.body))
            revision += 1
            // 303 rather than echoing the page: it turns the browser's reload into a GET, so a
            // viewer who refreshes does not re-post the form they already saved.
            send(status: "303 See Other", headers: ["Location": "/"], body: "", on: connection)
        } else {
            send(status: "200 OK", headers: ["Content-Type": "text/html; charset=utf-8"],
                 body: page(), on: connection)
        }
    }

    private func send(status: String, headers: [String: String], body: String, on connection: NWConnection) {
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"

        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection) }
        })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }
}

/// Just enough of a request to tell a form post from a page load.
struct HTTPRequest {
    var method: String
    var path: String
    var body: Data

    /// Returns `nil` while the request is still arriving, so the caller keeps reading.
    init?(_ buffer: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }

        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1])

        let declared = lines
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)) }
            ?? 0

        let available = buffer[headerEnd.upperBound...]
        guard available.count >= declared else { return nil }
        body = Data(available.prefix(declared))
    }
}

/// `application/x-www-form-urlencoded`, which is what a plain HTML form posts.
enum FormDecoder {
    static func decode(_ body: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first.map(String.init) else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            fields[unescape(name)] = unescape(value)
        }
        return fields
    }

    /// `+` for space is the form encoding's own rule and predates percent-escaping, so
    /// `removingPercentEncoding` alone leaves every space as a plus.
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? text.replacingOccurrences(of: "+", with: " ")
    }
}

/// The Apple TV's address on the local network.
enum LocalNetworkAddress {
    /// `en0` first, then any other `en` interface. Which of Ethernet and Wi-Fi gets `en0` varies
    /// by Apple TV model, so this is a preference for the primary interface rather than a claim
    /// about which medium it is; an Apple TV with both up answers on either address anyway.
    static func current() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var wired: String?
        var wireless: String?

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard interface.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                interface.pointee.ifa_addr,
                socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            let address = String(cString: host)
            if name.hasPrefix("en0") { wired = wired ?? address }
            else if name.hasPrefix("en") { wireless = wireless ?? address }
        }
        return wired ?? wireless
    }
}
