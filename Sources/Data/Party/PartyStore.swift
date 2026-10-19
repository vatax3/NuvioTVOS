import Foundation
import Observation
import os

/// This device's identity in a party, which has to outlive a relaunch.
///
/// Membership is keyed on it, so a device that mints a new id on every launch rejoins its own
/// party as a second person — and the first one sits there as a ghost until the backend times it
/// out. `UserDefaults` is the only storage tvOS does not reclaim.
enum PartyDevice {
    private static let key = "party.device_id"

    static var id: String {
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let minted = UUID().uuidString
        UserDefaults.standard.set(minted, forKey: key)
        return minted
    }
}

/// A watch party, from this device's side.
///
/// Two channels carry the session and they do different jobs, which is the thing to hold on to
/// when reading this:
///
/// - **The realtime channel** carries what changes constantly — positions, pauses, presence. It
///   is fast and lossy: a socket that drops has simply missed whatever happened while it was
///   away.
/// - **The RPCs** carry what has to be true — membership, the current title, the last known
///   position. The heartbeat's answer is therefore not just a keep-alive, it is the resync.
///
/// Every position on the wire is timestamped against the **server's** clock. Two televisions in
/// one house can be seconds apart, and a position stamped locally would be corrected by exactly
/// that error on arrival. The offset is measured once per snapshot and applied to everything.
@Observable
@MainActor
final class PartyStore {
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "Party")

    /// How often membership is refreshed. Short enough that a dropped member disappears from the
    /// roster while people are still looking at it, long enough not to be a poll.
    private static let heartbeatInterval: Duration = .seconds(20)

    // MARK: What the interface reads

    private(set) var party: ActiveParty?
    /// The party's authoritative playback state, which the player corrects itself against.
    private(set) var playback: PartyPlayback?
    /// A link someone shared, so the other members can open the same file.
    private(set) var sharedStream: PartyStream?
    private(set) var isBusy = false
    private(set) var error: PartyError?
    /// "Alex paused" — the last attributed action, for one line on screen.
    private(set) var notice: PartyNotice?
    private(set) var lastEvent: PartyEvent?
    /// Whether the backend has the feature on at all. Asked before the screen is offered.
    private(set) var isAvailable = false

    var isActive: Bool { party != nil }

    // MARK: Private state

    private let realtime = NuvioRealtime()
    private var identity: PartyIdentity?
    /// Server clock minus local clock, in milliseconds.
    private var clockOffsetMs: Int64 = 0
    private var sequence: Int64 = 0
    private var heartbeatTask: Task<Void, Never>?
    /// Set while this device is applying a correction, so its own corrected position is not
    /// republished as a command — which is how two devices chase each other.
    private var isApplyingCorrection = false
    private var reconnectTask: Task<Void, Never>?
    /// How many times the channel has been reopened without a join landing, which sets how long
    /// to wait before the next attempt.
    private var reconnectAttempt = 0

    // MARK: Availability

    func refreshAvailability(isSignedIn: Bool) async {
        guard isSignedIn else {
            isAvailable = false
            return
        }
        isAvailable = await PartyApi.isEnabled()
    }

    /// Server time now, which is what every position is measured against.
    var serverNowMs: Int64 { Self.localNowMs() + clockOffsetMs }

    private static func localNowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: Joining

    func preview(code: String) async -> PartyPreview? {
        do {
            return try await PartyApi.preview(code: Self.normalise(code))
        } catch let failure as PartyError {
            error = failure
            return nil
        } catch {
            self.error = .network
            return nil
        }
    }

    func create(media: PartyMedia, identity: PartyIdentity) async {
        await run(identity: identity) {
            try await PartyApi.create(
                identity: identity, media: media, playback: nil
            )
        }
    }

    func join(code: String, identity: PartyIdentity) async {
        await run(identity: identity) {
            try await PartyApi.join(code: Self.normalise(code), identity: identity)
        }
    }

    /// A code is read off a television screen and typed on a remote, so it is matched
    /// case-insensitively and without the spaces people put in it.
    static func normalise(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private func run(
        identity: PartyIdentity, _ operation: () async throws -> PartySnapshot
    ) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }

        do {
            let snapshot = try await operation()
            self.identity = identity
            apply(snapshot)
            guard party != nil else {
                error = .network
                return
            }
            await openChannel()
            startHeartbeat()
        } catch let failure as PartyError {
            error = failure
        } catch {
            self.error = .network
        }
    }

    // MARK: Leaving

    func leave() async {
        guard let party, let identity else { return }
        await teardown()
        _ = try? await PartyApi.leave(partyId: party.id, deviceId: identity.deviceId)
    }

    /// The host ending it for everybody, as opposed to leaving it running.
    func end() async {
        guard let party, let identity else { return }
        await teardown()
        _ = try? await PartyApi.end(partyId: party.id, deviceId: identity.deviceId)
    }

    private func teardown() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await realtime.close()
        party = nil
        playback = nil
        sharedStream = nil
        notice = nil
        // After `party` is cleared, so the `connected(false)` that closing the socket reports
        // cannot schedule a reconnect to a party we have just left.
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
    }

    // MARK: The host's controls

    func setHostOnly(_ hostOnly: Bool) async {
        guard let party, let identity, party.isHost else { return }
        guard let snapshot = try? await PartyApi.setHostOnly(
            partyId: party.id, deviceId: identity.deviceId, hostOnly: hostOnly
        ) else { return }
        apply(snapshot)
        await realtime.broadcast(event: "control", payload: ["host_only": hostOnly])
    }

    func remove(memberId: String) async {
        guard let party, let identity, party.isHost else { return }
        guard let snapshot = try? await PartyApi.removeMember(
            partyId: party.id, deviceId: identity.deviceId, memberId: memberId
        ) else { return }
        apply(snapshot)
    }

    // MARK: What the player publishes

    /// Announces where this device has taken playback.
    ///
    /// Refused when this device may not drive — with *host only* on, a guest's pause is their
    /// own business and must not move everybody else. Also refused while a correction is being
    /// applied: republishing a position we were just told to adopt is how two devices end up
    /// chasing each other around the film.
    func publish(
        positionMs: Int64, paused: Bool, rate: Double, mediaKey: String?, waiting: Bool = false
    ) async {
        guard let party, party.canControl, !isApplyingCorrection else { return }
        sequence += 1
        let state = PartyPlayback(
            seq: sequence,
            memberId: party.memberId,
            paused: paused,
            positionMs: positionMs,
            rate: rate,
            at: serverNowMs,
            mediaKey: mediaKey,
            waiting: waiting
        )
        playback = state
        await realtime.broadcast(event: "state", payload: Self.encode(state))
        // Also written through, so a member who joins after this survives a socket that drops:
        // the realtime channel has no history and the heartbeat's snapshot is the only thing
        // that does.
        if let identity {
            _ = try? await PartyApi.update(
                partyId: party.id, deviceId: identity.deviceId, media: nil, playback: state
            )
        }
    }

    /// Runs `body` without its resulting position being republished.
    func applyingCorrection(_ body: () -> Void) {
        isApplyingCorrection = true
        body()
        // Cleared on the next turn rather than immediately: the engine reports the new position
        // asynchronously, and clearing synchronously would let that report through as a command.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            isApplyingCorrection = false
        }
    }

    /// Shares the resolved link, so everyone opens the same file.
    ///
    /// **Worth being explicit about, because it is the one thing in this feature a viewer should
    /// be told rather than discover**: for us the URL is usually a debrid link tied to the
    /// sharer's own account, so the party streams through it. Loopback URLs are excluded — the
    /// host's own machine means nothing to anybody else — but there is no hiding what a shared
    /// link is, so the interface says so before this is called.
    func share(stream: PartyStream) async {
        guard let party, PartyStream.isShareable(stream.url) else { return }
        sharedStream = stream
        await realtime.broadcast(event: "stream", payload: Self.encode(stream))
        _ = party
    }

    /// Announces a change of title, which also clears the shared link: a URL belongs to one file.
    func change(media: PartyMedia) async {
        guard let party, let identity, party.canControl else { return }
        sharedStream = nil
        playback = nil
        guard let snapshot = try? await PartyApi.update(
            partyId: party.id, deviceId: identity.deviceId, media: media, playback: nil
        ) else { return }
        apply(snapshot)
        await realtime.broadcast(event: "media", payload: Self.encode(media))
    }

    /// Publishes what this device is doing, so the others can wait for it rather than run ahead.
    func report(status: PartyMemberStatus, mediaKey: String?, behindMs: Int64? = nil) async {
        guard let party else { return }
        await realtime.track(
            PartyPresence(
                memberId: party.memberId, status: status, mediaKey: mediaKey, behindMs: behindMs
            )
        )
    }

    // MARK: Realtime

    /// Reopens the channel after a backoff, for as long as there is still a party to reopen it
    /// for.
    ///
    /// 1.0.48 had none of this: a socket that failed to open stayed shut for the life of the
    /// party, which turned one bad URL into a session that could never recover. The delay grows
    /// so that a backend outage is waited out rather than polled.
    private func scheduleReconnect() {
        guard party != nil, reconnectTask == nil else { return }
        let attempt = reconnectAttempt
        reconnectAttempt += 1
        let seconds = min(30, 3 << min(attempt, 4))
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            await self?.openChannel()
        }
    }

    private func openChannel() async {
        guard let party, let identity,
              let credentials = await NuvioBackend.shared.realtimeCredentials()
        else {
            // No credentials means no socket at all, and no amount of retrying fixes that.
            error = .unavailable
            self.party?.isConnected = false
            return
        }

        // Measured against the live backend: a join carrying no JWT is refused outright with
        // "MalformedJWT". Retrying that forever would be a loop with no way out of it, so it is
        // reported as what it is.
        guard let token = credentials.token else {
            error = .signInRequired
            self.party?.isConnected = false
            return
        }

        do {
            try await realtime.open(
                backendUrl: credentials.backendUrl,
                publishableKey: credentials.key,
                accessToken: token,
                channel: "watch-party:\(party.id)",
                presenceKey: party.memberId
            ) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            await report(status: .browsing, mediaKey: party.media.key)
            // A joiner has no idea where the film is; whoever is leading answers.
            await realtime.broadcast(event: "state_request", payload: ["member_id": party.memberId])
            _ = identity
        } catch {
            log.error("Could not open the party channel: \(error.localizedDescription, privacy: .public)")
            self.party?.isConnected = false
            // Said out loud rather than only logged. A party whose socket never opens looks
            // joined — right code, right roster — and simply never moves, which is the single
            // most confusing state this feature can be in.
            self.error = .network
            scheduleReconnect()
        }
    }

    private func handle(_ event: NuvioRealtime.Event) {
        switch event {
        case .connected(let connected):
            party?.isConnected = connected
            if connected {
                reconnectAttempt = 0
                reconnectTask?.cancel()
                reconnectTask = nil
                if error == .network { error = nil }
            } else {
                scheduleReconnect()
            }

        case .presence(let presence):
            party?.presence = presence

        case .message(let name, let payload):
            handle(message: name, payload: payload)
        }
    }

    private func handle(message name: String, payload: [String: Any]) {
        switch name {
        case "state":
            guard let incoming: PartyPlayback = Self.decode(payload) else { return }
            adopt(incoming)

        case "state_request":
            // Only the device leading the party answers, or every member replies at once and the
            // joiner adopts whichever arrived last.
            guard let party, PartySync.coordinatorId(for: party) == party.memberId,
                  let playback
            else { return }
            Task { await realtime.broadcast(event: "state", payload: Self.encode(playback)) }

        case "stream":
            guard let stream: PartyStream = Self.decode(payload) else { return }
            sharedStream = stream

        case "media":
            guard let media: PartyMedia = Self.decode(payload) else { return }
            party?.media = media
            playback = nil
            sharedStream = nil
            lastEvent = .mediaChanged(media)

        case "control":
            let hostOnly = payload["host_only"] as? Bool ?? false
            party?.hostOnly = hostOnly
            lastEvent = .controlChanged(hostOnly: hostOnly)

        case "ended":
            lastEvent = .ended
            Task { await teardown() }

        case "member_joined", "member_left":
            // The roster itself comes from the heartbeat; the broadcast only says to look now
            // rather than in twenty seconds.
            Task { await refreshMembership() }

        default:
            break
        }
    }

    /// Takes on an incoming playback state, if it supersedes what we are already acting on.
    private func adopt(_ incoming: PartyPlayback) {
        guard PartySync.isNewer(incoming, than: playback) else { return }
        let previous = playback
        playback = incoming
        sequence = max(sequence, incoming.seq)

        // Attributed, because an unexplained jump in someone else's hands is the most confusing
        // thing a shared session can do. Our own actions are not announced back to us.
        guard incoming.memberId != party?.memberId,
              let action = PartySync.action(from: previous, to: incoming),
              let name = party?.member(incoming.memberId)?.displayName
        else { return }
        notice = PartyNotice(
            name: name, action: action, positionMs: incoming.positionMs, rate: incoming.rate
        )
    }

    // MARK: Membership

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled else { return }
                await self?.refreshMembership()
            }
        }
    }

    private func refreshMembership() async {
        guard let party, let identity else { return }
        do {
            apply(try await PartyApi.heartbeat(partyId: party.id, deviceId: identity.deviceId))
        } catch let failure as PartyError {
            // Removed or ended is final: stop rather than keep asking a party we are not in.
            switch failure {
            case .removed, .ended, .notFound:
                lastEvent = failure == .removed ? .removed : .ended
                await teardown()
            default:
                break
            }
        } catch {
            // A failed heartbeat is a network blip, not an eviction.
            log.debug("Party heartbeat failed")
        }
    }

    /// Folds a snapshot into what the interface is showing.
    private func apply(_ snapshot: PartySnapshot) {
        if let serverTimeMs = snapshot.serverTimeMs {
            clockOffsetMs = serverTimeMs - Self.localNowMs()
        }
        guard let info = snapshot.party, let memberId = snapshot.memberId ?? party?.memberId else {
            return
        }

        let previousNames = Set(party?.members.map(\.id) ?? [])
        party = ActiveParty(
            id: info.id,
            code: info.code,
            memberId: memberId,
            hostMemberId: info.hostMemberId,
            members: snapshot.members,
            // Presence is the channel's, not the snapshot's, so it is carried across rather than
            // cleared: a heartbeat landing between two presence frames would otherwise empty the
            // roster's status badges for a moment.
            presence: party?.presence ?? [:],
            media: info.media,
            maxMembers: info.maxMembers,
            isConnected: party?.isConnected ?? false,
            hostOnly: info.hostOnly
        )

        if let incoming = info.playback { adopt(incoming) }

        // Arrivals and departures, named — reported from the roster rather than the broadcast so
        // a member who joined while our socket was down is still announced.
        if !previousNames.isEmpty {
            let current = Set(snapshot.members.map(\.id))
            if let joined = snapshot.members.first(where: { !previousNames.contains($0.id) }) {
                lastEvent = .memberJoined(joined.displayName)
            } else if previousNames.subtracting(current).first != nil {
                lastEvent = .memberLeft(
                    L10n.text("party.someone", fallback: "Someone")
                )
            }
        }
    }

    func clearNotice() { notice = nil }
    func clearEvent() { lastEvent = nil }
    func clearError() { error = nil }

    // MARK: JSON

    private static func encode<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func decode<T: Decodable>(_ payload: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
