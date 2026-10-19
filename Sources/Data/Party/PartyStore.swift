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
    private var clock = PartyClock()
    private var sequence: Int64 = 0
    private var heartbeatTask: Task<Void, Never>?
    /// Set while this device is applying a correction, so its own corrected position is not
    /// republished as a command — which is how two devices chase each other.
    private var isApplyingCorrection = false
    private var reconnectTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var coordinatorTask: Task<Void, Never>?
    /// What this device last told the room about itself.
    private var localPresence: PartyPresence?
    /// Members whose buffering has already been waited out once, so one slow connection cannot
    /// hold the party still indefinitely.
    private var ignoredWaiting: Set<String> = []
    private var waitStartedAt: ContinuousClock.Instant?
    private var resumedAt: ContinuousClock.Instant?
    private var isRejoining = false
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
    var serverNowMs: Int64 { clock.nowMs() }

    /// Measures the offset properly, a few times, just after joining.
    ///
    /// The snapshot's `server_time_ms` anchors it immediately so the party is usable at once;
    /// these samples then replace that anchor with a round-trip-compensated one. See
    /// `PartyClock` for why the difference is not cosmetic.
    private func refineClock() {
        Task { @MainActor [weak self] in
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.party != nil else { return }
                let sentAt = self.clock.mark()
                guard let serverMs = try? await PartyApi.clock() else { continue }
                self.clock.addSample(serverMs: serverMs, sentAt: sentAt)
            }
        }
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
            clock.reset()
            if let serverTimeMs = snapshot.serverTimeMs {
                clock.addSample(serverMs: serverTimeMs, sentAt: clock.mark())
            }
            localPresence = nil
            ignoredWaiting = []
            waitStartedAt = nil
            resumedAt = nil
            await openChannel()
            startHeartbeat()
            startCoordinator()
            refineClock()
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
        coordinatorTask?.cancel()
        coordinatorTask = nil
        persistTask?.cancel()
        persistTask = nil
        statusTask?.cancel()
        statusTask = nil
        localPresence = nil
        ignoredWaiting = []
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
        schedulePersist()
    }

    /// Writes the latest position through to the record, well after the broadcast.
    ///
    /// Both are needed and they are not the same job: the broadcast is what the others act on,
    /// and the record is what a member who joins later — or whose socket dropped — reads. But
    /// the record only has to be *roughly* current, and 1.0.49 called the RPC on every single
    /// publish. With the player loop now publishing on seeks and re-anchors as well, that would
    /// be a request every few hundred milliseconds. Upstream debounces by 1.5s; so do we.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, let party = self.party,
                  let identity = self.identity, let playback = self.playback
            else { return }
            if let snapshot = try? await PartyApi.update(
                partyId: party.id, deviceId: identity.deviceId, media: nil, playback: playback
            ) {
                self.apply(snapshot)
            }
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
    func share(stream: PartyStream?) async {
        guard let party, party.isHost, party.isSharing else { return }
        let offered = stream.flatMap { PartyStream.isShareable($0.url) ? $0 : nil }
        guard offered != sharedStream else { return }
        await sendStream(offered)
    }

    /// Turns the host's sharing on or off. Turning it off withdraws the link.
    func setSharing(_ sharing: Bool) async {
        guard let party, party.isHost, party.isSharing != sharing else { return }
        self.party?.isSharing = sharing
        if !sharing { await sendStream(nil) }
    }

    /// The wire shape, which is **not** the stream on its own.
    ///
    /// `{member_id, stream}`, with a null stream meaning "withdrawn". 1.0.48 broadcast the
    /// `PartyStream` flat, so the official app's share decoded to nothing here and ours to
    /// nothing there — the client was silently offered its own source list instead, which is
    /// exactly what it looks like when the feature is simply not implemented.
    private func sendStream(_ stream: PartyStream?) async {
        guard let party else { return }
        sharedStream = stream
        await realtime.broadcast(event: "stream", payload: [
            "member_id": party.memberId,
            "stream": stream.map { Self.encode($0) } ?? NSNull()
        ])
    }

    /// Announces a change of title, which also clears the shared link: a URL belongs to one file.
    func change(media: PartyMedia) async {
        // The host's call alone. A guest moving to the next episode moves themselves, not the
        // room — upstream's `publishMedia` takes the same line.
        guard let party, let identity, party.isHost, media != party.media else { return }
        let sameContent = media.key == party.media.key
        self.party?.media = media
        if !sameContent {
            sharedStream = nil
            playback = nil
        }
        // `{media, playback}` — the envelope the official app reads. A flat `PartyMedia` is
        // dropped on arrival.
        await realtime.broadcast(event: "media", payload: [
            "media": Self.encode(media),
            "playback": playback.map { Self.encode($0) } ?? NSNull()
        ])
        if let snapshot = try? await PartyApi.update(
            partyId: party.id, deviceId: identity.deviceId, media: media, playback: playback
        ) {
            apply(snapshot)
        }
    }

    /// Publishes what this device is doing, so the others can wait for it rather than run ahead.
    ///
    /// **Over a broadcast, not over presence**, which is the distinction 1.0.48 missed. Phoenix
    /// presence is tracked once per connection and the official app ignores a presence join for
    /// a key it already holds — so a status change sent only by re-tracking is invisible to it,
    /// and theirs was invisible to us. Every member therefore sat frozen at whatever they
    /// happened to be doing when they connected, which is why the roster read *Offline*.
    ///
    /// Debounced, because the player reports its state several times a second and the room only
    /// needs to know when it settles.
    func report(status: PartyMemberStatus, mediaKey: String?, behindMs: Int64? = nil) {
        guard let party else { return }
        let next = PartyPresence(
            memberId: party.memberId, status: status, mediaKey: mediaKey, behindMs: behindMs
        )
        guard next != localPresence else { return }
        localPresence = next
        self.party?.presence[party.memberId] = next
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.realtime.broadcast(event: "status", payload: Self.encode(next))
        }
    }

    /// This device's presence as the room should see it.
    private func ownPresence() -> PartyPresence {
        localPresence ?? PartyPresence(memberId: party?.memberId ?? "")
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
            _ = identity
            // Everything a (re)connected device has to say is said in `announce`, which runs on
            // the channel's own connected event rather than here: a reconnect has to re-announce
            // too, and there is no second call to this method for it to hang off.
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
                Task { await announce() }
            } else {
                // Everyone else's presence is no longer knowable; ours still is. Keeping stale
                // entries would show a roster of people who may have left while we were away.
                if let memberId = party?.memberId {
                    party?.presence = party?.presence.filter { $0.key == memberId } ?? [:]
                }
                scheduleReconnect()
            }

        case .presence(let presence):
            // Presence carries arrival and departure; *what* a member is doing arrives on the
            // `status` broadcast instead, so an entry we already hold is not overwritten by the
            // stale state tracked when they connected.
            guard let current = party?.presence else { return }
            var merged = current.filter { presence[$0.key] != nil || $0.key == party?.memberId }
            for (key, value) in presence where merged[key] == nil {
                merged[key] = value
            }
            party?.presence = merged

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
            // Answered by anybody who knows where the film is, not only by the coordinator: a
            // joiner's first question has to be answered by *someone*, and the device leading
            // the party is often not the one holding a position yet.
            guard let party, payload["member_id"] as? String != party.memberId else { return }
            Task { await answerStateRequest() }

        case "status":
            guard let incoming: PartyPresence = Self.decode(payload),
                  incoming.memberId != party?.memberId
            else { return }
            if incoming.status == .ready { ignoredWaiting.remove(incoming.memberId) }
            party?.presence[incoming.memberId] = incoming

        case "stream":
            // `{member_id, stream}`. Only the host's share counts, and a null stream withdraws
            // what they offered before.
            guard let party, !party.isHost,
                  payload["member_id"] as? String == party.hostMemberId
            else { return }
            let offered: PartyStream? = (payload["stream"] as? [String: Any]).flatMap(Self.decode)
            sharedStream = offered.flatMap { PartyStream.isShareable($0.url) ? $0 : nil }

        case "media":
            // `{media, playback}` — the title and, when the room moved with it, where it is.
            guard let object = payload["media"] as? [String: Any],
                  let media: PartyMedia = Self.decode(object)
            else { return }
            let incoming: PartyPlayback? = (payload["playback"] as? [String: Any])
                .flatMap(Self.decode)
            applyMedia(media, playback: incoming)

        case "control":
            guard let hostOnly = payload["host_only"] as? Bool,
                  let party, party.hostOnly != hostOnly
            else { return }
            self.party?.hostOnly = hostOnly
            // Announced to the people it constrains, not to the host who just chose it.
            if !party.isHost { lastEvent = .controlChanged(hostOnly: hostOnly) }

        case "member_joined":
            Task { await refreshMembership(announcing: payload["member_id"] as? String) }

        case "member_left":
            handleMemberLeft(
                memberId: payload["member_id"] as? String,
                reason: payload["reason"] as? String,
                hostMemberId: payload["host_member_id"] as? String
            )

        case "ended":
            // `disabled` is the feature being switched off at the backend, not this party
            // finishing — so the screen stops offering parties at all rather than inviting the
            // viewer to start another one.
            if payload["reason"] as? String == "disabled" { isAvailable = false }
            lastEvent = .ended
            Task { await teardown() }

        default:
            break
        }
    }

    /// Everything a freshly connected device owes the room.
    ///
    /// Order matters a little: presence first so the others can see us at all, then what we are
    /// doing, then what we know — a position and, if we are the sharing host, the link.
    private func announce() async {
        guard let party else { return }
        await realtime.track(ownPresence())
        await realtime.broadcast(event: "status", payload: Self.encode(ownPresence()))
        if let playback {
            await realtime.broadcast(event: "state", payload: Self.encode(playback))
        }
        if party.isHost, party.isSharing, let sharedStream {
            await sendStream(sharedStream)
        }
        await realtime.broadcast(event: "state_request", payload: ["member_id": party.memberId])
    }

    private func answerStateRequest() async {
        guard let party else { return }
        await realtime.broadcast(event: "status", payload: Self.encode(ownPresence()))
        if party.isHost, party.isSharing, let sharedStream {
            await sendStream(sharedStream)
        }
        guard let playback else { return }
        await realtime.broadcast(event: "state", payload: Self.encode(playback))
    }

    /// A change of title, from somebody else.
    private func applyMedia(_ media: PartyMedia, playback incoming: PartyPlayback?) {
        guard let party else { return }
        let changed = media.key != party.media.key
        self.party?.media = media
        guard changed else {
            if let incoming { adopt(incoming) }
            return
        }
        playback = incoming.flatMap { $0.mediaKey == nil || $0.mediaKey == media.key ? $0 : nil }
        if sharedStream?.mediaKey != media.key { sharedStream = nil }
        ignoredWaiting = []
        waitStartedAt = nil
        lastEvent = .mediaChanged(media)
    }

    /// Somebody left — possibly us.
    ///
    /// Being named here ourselves is not the same as leaving: the backend drops a member whose
    /// heartbeat lapsed, and the right answer to that is to rejoin rather than to sit in a party
    /// that no longer lists us. Being *removed* is final.
    private func handleMemberLeft(memberId: String?, reason: String?, hostMemberId: String?) {
        guard let party, let memberId else { return }
        if memberId == party.memberId {
            if reason == "removed" {
                lastEvent = .removed
                Task { await teardown() }
            } else {
                Task { await rejoinOrFinish() }
            }
            return
        }
        let name = party.member(memberId)?.displayName
        if memberId == party.hostMemberId { sharedStream = nil }
        self.party?.members.removeAll { $0.id == memberId }
        self.party?.presence.removeValue(forKey: memberId)
        if let hostMemberId { self.party?.hostMemberId = hostMemberId }
        ignoredWaiting.remove(memberId)
        if let name { lastEvent = .memberLeft(name) }
    }

    /// Rejoins with the code we already have, and gives up only if that fails.
    private func rejoinOrFinish() async {
        guard let party, let identity, !isRejoining else { return }
        isRejoining = true
        defer { isRejoining = false }

        guard let snapshot = try? await PartyApi.join(code: party.code, identity: identity),
              snapshot.error == nil, snapshot.party != nil
        else {
            lastEvent = .ended
            await teardown()
            return
        }
        apply(snapshot)
        await openChannel()
    }

    /// Takes on an incoming playback state, if it supersedes what we are already acting on.
    private func adopt(_ incoming: PartyPlayback) {
        guard let party else { return }
        // Not a command about this title at all.
        if let key = incoming.mediaKey, key != party.media.key { return }
        // **With *host only* on, nobody but the host moves the room.** Enforced on the receiving
        // side as well as the sending one, so a guest whose client is out of date — or simply
        // slow to learn the setting changed — cannot drag everybody with them.
        if party.hostOnly, incoming.memberId != party.hostMemberId { return }
        guard PartySync.isNewer(incoming, than: playback) else { return }
        let previous = playback
        playback = incoming
        sequence = max(sequence, incoming.seq)

        // A resume starts a grace period before the coordinator may pause the room again for a
        // member who is still buffering, and forgives whoever it was waiting for.
        if let previous, previous.paused, !incoming.paused {
            resumedAt = ContinuousClock.now
            if previous.waiting {
                ignoredWaiting.formUnion(PartySync.waitingMemberIds(in: party, ignoring: []))
            }
        }

        // Attributed, because an unexplained jump in someone else's hands is the most confusing
        // thing a shared session can do. Our own actions are not announced back to us.
        guard incoming.memberId != party.memberId,
              let action = PartySync.action(from: previous, to: incoming),
              let name = party.member(incoming.memberId)?.displayName
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

    private func refreshMembership(announcing memberId: String? = nil) async {
        guard let party, let identity else { return }
        do {
            let known = Set(self.party?.members.map(\.id) ?? [])
            apply(try await PartyApi.heartbeat(partyId: party.id, deviceId: identity.deviceId))
            if let memberId, memberId != party.memberId, !known.contains(memberId),
               let name = self.party?.member(memberId)?.displayName {
                lastEvent = .memberJoined(name)
            }
        } catch let failure as PartyError {
            switch failure {
            case .removed:
                lastEvent = .removed
                await teardown()
            case .ended, .notFound:
                lastEvent = .ended
                await teardown()
            case .network:
                // The backend says we are not a member. That is usually a lapsed heartbeat
                // rather than an eviction, and the answer to it is to rejoin with the code we
                // still hold rather than to sit in a party that no longer lists us.
                await rejoinOrFinish()
            default:
                break
            }
        } catch {
            // A failed heartbeat is a network blip, not an eviction.
            log.debug("Party heartbeat failed")
        }
    }

    // MARK: Waiting for each other

    /// Holds the party still while somebody is still loading, and lets it go again.
    ///
    /// Only the coordinator runs it, or every device would publish the same pause at once. The
    /// rule is upstream's and the two limits are what keep it humane: a resume is given three
    /// seconds of grace before anyone may pause the room again, and nobody is waited for longer
    /// than fifteen — one slow connection must not hold four people indefinitely.
    private func startCoordinator() {
        coordinatorTask?.cancel()
        coordinatorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                await self.coordinate()
            }
        }
    }

    private func coordinate() async {
        guard let party, party.isConnected,
              PartySync.coordinatorId(for: party) == party.memberId,
              let playback
        else {
            waitStartedAt = nil
            return
        }
        guard playback.mediaKey == nil || playback.mediaKey == party.media.key else { return }
        let waiting = PartySync.waitingMemberIds(in: party, ignoring: ignoredWaiting)

        if !playback.paused {
            let graceOver = resumedAt.map { ContinuousClock.now - $0 > .seconds(3) } ?? true
            guard !waiting.isEmpty, graceOver else { return }
            let position = PartySync.expectedPositionMs(playback, nowMs: serverNowMs)
            await publish(
                positionMs: position, paused: true, rate: playback.rate,
                mediaKey: party.media.key, waiting: true
            )
            waitStartedAt = ContinuousClock.now
        } else if playback.waiting {
            let started = waitStartedAt ?? ContinuousClock.now
            waitStartedAt = started
            guard waiting.isEmpty || ContinuousClock.now - started > .seconds(15) else { return }
            ignoredWaiting.formUnion(waiting)
            await publish(
                positionMs: playback.positionMs, paused: false, rate: playback.rate,
                mediaKey: party.media.key, waiting: false
            )
        }
    }

    /// Folds a snapshot into what the interface is showing.
    private func apply(_ snapshot: PartySnapshot) {
        if let serverTimeMs = snapshot.serverTimeMs, !clock.isSynced {
            // A first, uncompensated anchor so positions mean something before `refineClock`
            // has measured anything. Replaced by the first real sample.
            clock.addSample(serverMs: serverTimeMs, sentAt: clock.mark())
        }
        guard let info = snapshot.party, let memberId = snapshot.memberId ?? party?.memberId else {
            return
        }

        let previousNames = Set(party?.members.map(\.id) ?? [])
        let mediaChanged = party.map { info.media.key != $0.media.key } ?? false
        let members = Set(snapshot.members.map(\.id))
        party = ActiveParty(
            id: info.id,
            code: info.code,
            memberId: memberId,
            hostMemberId: info.hostMemberId,
            members: snapshot.members,
            // Presence is the channel's, not the snapshot's, so it is carried across rather than
            // cleared: a heartbeat landing between two presence frames would otherwise empty the
            // roster's status badges for a moment. Anybody no longer on the roster goes.
            presence: (party?.presence ?? [:]).filter { members.contains($0.key) },
            media: info.media,
            maxMembers: info.maxMembers,
            isConnected: party?.isConnected ?? false,
            hostOnly: info.hostOnly,
            // Sharing is this device's own decision and is not in the record — rebuilding the
            // party from a snapshot must not quietly switch it off.
            isSharing: party?.isSharing ?? false
        )

        if mediaChanged {
            applyMedia(info.media, playback: info.playback)
        } else if let incoming = info.playback {
            adopt(incoming)
        }

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
