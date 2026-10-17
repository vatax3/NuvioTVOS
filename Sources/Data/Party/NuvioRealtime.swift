import Foundation
import os

/// A Phoenix channel over a WebSocket, which is the transport a watch party runs on.
///
/// Upstream uses the supabase-kt SDK's Realtime client. We have no SDK, so this speaks the
/// protocol directly — which is small enough to be worth doing and specific enough to be worth
/// writing down:
///
/// - One socket to `wss://<host>/realtime/v1/websocket?apikey=<key>&vsn=1.0.0`.
/// - Every frame is `{topic, event, payload, ref}`. A request is answered by `phx_reply` with the
///   same `ref`, so replies are matched on it rather than on arrival order.
/// - `phx_join` enters a topic. A **private** channel — which a watch party is — then requires
///   `access_token` to be pushed with the account's JWT, or the server accepts the join and
///   silently delivers nothing.
/// - A heartbeat on topic `phoenix` every 30 seconds, or the server closes the socket. This is
///   the mistake that looks like a working implementation for exactly thirty seconds.
/// - Presence arrives as `presence_state` once on join, then `presence_diff` with joins/leaves.
///
/// Everything here is about framing and liveness. What the party *means* by a message is
/// `PartyStore`'s business, and the sync arithmetic is `PartySync`'s.
actor NuvioRealtime {
    /// What a channel reports upwards.
    enum Event: Sendable {
        /// A broadcast from another member: the event name and its payload.
        case message(event: String, payload: [String: Any])
        /// The current presence set, already merged.
        case presence([String: PartyPresence])
        /// The channel finished joining, or went away.
        case connected(Bool)
    }

    private let log = Logger(subsystem: "com.nuvio.tvos", category: "Realtime")
    /// Phoenix requires a heartbeat inside its own timeout; 30s is the documented interval and
    /// the server's patience is 60.
    private static let heartbeatInterval: Duration = .seconds(30)
    /// How long to wait for `phx_reply` on a join before calling it a failure.
    private static let joinTimeout: Duration = .seconds(10)

    private var socket: URLSessionWebSocketTask?
    private let session: URLSession
    private var topic: String?
    private var presenceKey: String?
    private var accessToken: String?
    private var handler: (@Sendable (Event) -> Void)?

    private var reference = 0
    private var joinReference: String?
    private var isJoined = false
    private var presence: [String: PartyPresence] = [:]
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Opening

    /// Opens the socket and joins `channel`, reporting everything through `onEvent`.
    ///
    /// - Parameter channel: the channel name without Phoenix's `realtime:` prefix.
    func open(
        backendUrl: String,
        publishableKey: String,
        accessToken: String?,
        channel: String,
        presenceKey: String,
        onEvent: @escaping @Sendable (Event) -> Void
    ) async throws {
        await close()

        guard let url = Self.socketURL(backendUrl: backendUrl, key: publishableKey) else {
            throw PartyError.unavailable
        }
        self.topic = "realtime:\(channel)"
        self.presenceKey = presenceKey
        self.accessToken = accessToken
        self.handler = onEvent

        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()

        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        try await join()
        heartbeatTask = Task { [weak self] in await self?.heartbeatLoop() }
    }

    /// `wss://<host>/realtime/v1/websocket?apikey=…&vsn=1.0.0`, derived from the REST base URL
    /// the account is already configured with rather than stored a second time.
    static func socketURL(backendUrl: String, key: String) -> URL? {
        var trimmed = backendUrl.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: key),
            URLQueryItem(name: "vsn", value: "1.0.0")
        ]
        return components.url
    }

    private func join() async throws {
        guard let topic, let presenceKey else { throw PartyError.unavailable }
        let ref = nextReference()
        joinReference = ref

        // `private: true` is what a watch party's channel is configured as upstream. Without the
        // access token below the server joins us to a channel that then delivers nothing — a
        // failure mode with no error attached to it, which is why the token is not optional here
        // in practice.
        try await send([
            "topic": topic,
            "event": "phx_join",
            "ref": ref,
            "payload": [
                "config": [
                    "private": true,
                    "broadcast": ["self": false, "ack": false],
                    "presence": ["key": presenceKey]
                ],
                "access_token": accessToken ?? ""
            ]
        ])

        // The join is not complete until the reply lands, and acting before it means broadcasts
        // sent into a channel that is not yet listening.
        let deadline = ContinuousClock.now + Self.joinTimeout
        while ContinuousClock.now < deadline {
            if isJoined { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw PartyError.network
    }

    // MARK: Sending

    /// Broadcasts to the other members. Silently dropped before the join completes, because a
    /// queued broadcast delivered after a rejoin is a command from the past.
    func broadcast(event: String, payload: [String: Any]) async {
        guard isJoined, let topic else { return }
        try? await send([
            "topic": topic,
            "event": "broadcast",
            "ref": nextReference(),
            "payload": ["type": "broadcast", "event": event, "payload": payload]
        ])
    }

    /// Publishes this device's presence, replacing whatever it published before.
    func track(_ presence: PartyPresence) async {
        guard isJoined, let topic, let payload = Self.encode(presence) else { return }
        try? await send([
            "topic": topic,
            "event": "presence",
            "ref": nextReference(),
            "payload": ["type": "presence", "event": "track", "payload": payload]
        ])
    }

    func close() async {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        isJoined = false
        presence = [:]
        joinReference = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        handler?(.connected(false))
    }

    private func send(_ frame: [String: Any]) async throws {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8)
        else { throw PartyError.network }
        try await socket.send(.string(text))
    }

    private func nextReference() -> String {
        reference += 1
        return String(reference)
    }

    // MARK: Receiving

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                guard case .string(let text) = message else { continue }
                handle(text)
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Realtime socket closed: \(error.localizedDescription, privacy: .public)")
                isJoined = false
                handler?(.connected(false))
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = frame["event"] as? String
        else { return }
        let payload = frame["payload"] as? [String: Any] ?? [:]

        switch event {
        case "phx_reply":
            // Matched on `ref`, not on being the next thing to arrive: a heartbeat reply can
            // overtake a join reply and would otherwise be read as one.
            guard frame["ref"] as? String == joinReference else { return }
            let status = payload["status"] as? String
            isJoined = status == "ok"
            handler?(.connected(isJoined))
            if !isJoined {
                log.error("Realtime join refused: \(status ?? "no status", privacy: .public)")
            }

        case "presence_state":
            presence = Self.decodePresenceState(payload)
            handler?(.presence(presence))

        case "presence_diff":
            applyPresenceDiff(payload)
            handler?(.presence(presence))

        case "broadcast":
            guard let name = payload["event"] as? String else { return }
            handler?(.message(event: name, payload: payload["payload"] as? [String: Any] ?? [:]))

        case "phx_close", "phx_error":
            isJoined = false
            handler?(.connected(false))

        default:
            break
        }
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.heartbeatInterval)
            guard !Task.isCancelled else { return }
            // Topic `phoenix`, not the channel's: the heartbeat keeps the *socket* alive.
            try? await send(["topic": "phoenix", "event": "heartbeat", "ref": nextReference(), "payload": [:]])
        }
    }

    // MARK: Presence

    /// Phoenix presence is `{key: {metas: [payload, …]}}`. The newest meta wins — a device that
    /// reconnected appears twice until the old entry times out.
    static func decodePresenceState(_ payload: [String: Any]) -> [String: PartyPresence] {
        var result: [String: PartyPresence] = [:]
        for (key, value) in payload {
            guard let entry = value as? [String: Any],
                  let metas = entry["metas"] as? [[String: Any]],
                  let last = metas.last,
                  let decoded = decode(last)
            else { continue }
            result[key] = decoded
        }
        return result
    }

    private func applyPresenceDiff(_ payload: [String: Any]) {
        if let leaves = payload["leaves"] as? [String: Any] {
            for key in leaves.keys { presence.removeValue(forKey: key) }
        }
        if let joins = payload["joins"] as? [String: Any] {
            for (key, value) in Self.decodePresenceState(joins) {
                presence[key] = value
            }
            // A key in `joins` that we could not decode still means somebody is there, so it
            // must not be dropped: an undecodable member silently absent from the roster reads
            // as having left.
            for key in joins.keys where presence[key] == nil {
                presence[key] = PartyPresence(memberId: key)
            }
        }
    }

    static func encode(_ presence: PartyPresence) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(presence),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    static func decode(_ object: [String: Any]) -> PartyPresence? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(PartyPresence.self, from: data)
    }
}
