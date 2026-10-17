import Foundation

/// The `watch_party_*` functions, on the backend this app already talks to.
///
/// Worth stating plainly, because the project's standing rule points the other way: upstream's
/// own endpoints are normally declined — the discovery service and the playback reports are both
/// absent here because their contracts are not in public source. Watch parties are the
/// exception, and not by special pleading: the function names and their parameters *are* in
/// public source, and `NuvioBackend` is already authenticated against the same Supabase instance
/// for account sync. Nothing had to be guessed.
enum PartyApi {
    // MARK: Availability

    /// Whether the backend has the feature switched on at all. Asked once before the screen is
    /// offered, so a viewer is never shown a party flow that cannot complete.
    static func isEnabled() async -> Bool {
        (try? await NuvioBackend.shared.rpc(
            "watch_party_enabled", as: Bool.self, authenticated: false
        )) ?? false
    }

    /// The server's clock in milliseconds.
    ///
    /// Load-bearing rather than a nicety: every position on the wire is timestamped against this
    /// clock, so two televisions whose own clocks differ by three seconds still agree on where
    /// the film is. Timestamping locally would bake each device's offset into every correction.
    static func clock() async throws -> Int64 {
        try await NuvioBackend.shared.rpc("watch_party_clock", as: Int64.self)
    }

    // MARK: Joining and leaving

    static func create(
        identity: PartyIdentity, media: PartyMedia, playback: PartyPlayback?
    ) async throws -> PartySnapshot {
        try await call("watch_party_create", parameters: identity.parameters.merging([
            "p_media": try media.asJSON(),
            "p_playback": try playback.asJSON()
        ]) { _, new in new })
    }

    static func join(code: String, identity: PartyIdentity) async throws -> PartySnapshot {
        try await call("watch_party_join", parameters: identity.parameters.merging([
            "p_code": .string(code)
        ]) { _, new in new })
    }

    /// What a code points at, before committing to it — so the viewer sees the title and who is
    /// already there rather than joining blind.
    static func preview(code: String) async throws -> PartyPreview {
        let preview = try await NuvioBackend.shared.rpc(
            "watch_party_preview", parameters: ["p_code": .string(code)], as: PartyPreview.self
        )
        if let error = PartyError.from(preview.error) { throw error }
        return preview
    }

    static func leave(partyId: String, deviceId: String) async throws -> PartySnapshot {
        try await call("watch_party_leave", parameters: [
            "p_party_id": .string(partyId), "p_device_id": .string(deviceId)
        ])
    }

    static func end(partyId: String, deviceId: String) async throws -> PartySnapshot {
        try await call("watch_party_end", parameters: [
            "p_party_id": .string(partyId), "p_device_id": .string(deviceId)
        ])
    }

    // MARK: Staying in it

    /// Keeps membership alive and returns the party as the server sees it.
    ///
    /// This is also the recovery path: the realtime channel carries the fast-moving state, and a
    /// socket that dropped and came back has missed whatever happened in between. The heartbeat's
    /// answer is the truth that resyncs it.
    static func heartbeat(partyId: String, deviceId: String) async throws -> PartySnapshot {
        try await call("watch_party_heartbeat", parameters: [
            "p_party_id": .string(partyId), "p_device_id": .string(deviceId)
        ])
    }

    static func update(
        partyId: String, deviceId: String, media: PartyMedia?, playback: PartyPlayback?
    ) async throws -> PartySnapshot {
        var parameters: [String: AnyJSONValue] = [
            "p_party_id": .string(partyId), "p_device_id": .string(deviceId)
        ]
        if let media { parameters["p_media"] = try media.asJSON() }
        if let playback { parameters["p_playback"] = try playback.asJSON() }
        return try await call("watch_party_update", parameters: parameters)
    }

    // MARK: The host's controls

    static func setHostOnly(
        partyId: String, deviceId: String, hostOnly: Bool
    ) async throws -> PartySnapshot {
        try await call("watch_party_set_host_only", parameters: [
            "p_party_id": .string(partyId),
            "p_device_id": .string(deviceId),
            "p_host_only": .bool(hostOnly)
        ])
    }

    static func removeMember(
        partyId: String, deviceId: String, memberId: String
    ) async throws -> PartySnapshot {
        try await call("watch_party_remove_member", parameters: [
            "p_party_id": .string(partyId),
            "p_device_id": .string(deviceId),
            "p_member_id": .string(memberId)
        ])
    }

    // MARK: Plumbing

    /// Every call answers a snapshot, and an error inside a 200 is still an error — the backend
    /// reports `party_full` and friends in the body, so a caller that only checks for a thrown
    /// network failure would read "full" as a successful join.
    private static func call(
        _ name: String, parameters: [String: AnyJSONValue]
    ) async throws -> PartySnapshot {
        let snapshot: PartySnapshot
        do {
            snapshot = try await NuvioBackend.shared.rpc(
                name, parameters: parameters, as: PartySnapshot.self
            )
        } catch {
            throw PartyError.network
        }
        if let error = PartyError.from(snapshot.error) { throw error }
        return snapshot
    }
}

private extension PartyIdentity {
    var parameters: [String: AnyJSONValue] {
        [
            "p_device_id": .string(deviceId),
            "p_display_name": .string(displayName),
            "p_avatar_url": avatarUrl.map(AnyJSONValue.string) ?? .null,
            "p_avatar_color": avatarColor.map(AnyJSONValue.string) ?? .null
        ]
    }
}

private extension Encodable {
    /// Re-encodes a model as `AnyJSONValue`, so the RPC body stays one `Encodable` tree rather
    /// than a string of pre-rendered JSON the server would have to parse twice.
    func asJSON() throws -> AnyJSONValue {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(AnyJSONValue.self, from: data)
    }
}

private extension Optional where Wrapped: Encodable {
    func asJSON() throws -> AnyJSONValue {
        guard let self else { return .null }
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(AnyJSONValue.self, from: data)
    }
}
