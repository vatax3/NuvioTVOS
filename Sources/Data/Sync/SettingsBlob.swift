import Foundation

/// The DataStore type a value carries in the settings blob — upstream's `encodePreferenceValue`.
enum SettingsBlobType: String, Sendable {
    case boolean, int, long, float, double, string
    case stringSet = "string_set"
}

/// The profile settings blob, in the Android app's own shape.
///
/// Both apps push and pull the same row: `sync_push_profile_settings_blob` with
/// `p_platform: "tv"`. Upstream writes `{version: 1, features: {player_settings: {key: {type,
/// value}}}}` (`ProfileSettingsSyncService.exportSettingsBlob`); this app wrote
/// `{player: {key: value}, …}`. Neither could read the other's, and whichever pushed last replaced
/// the other's settings outright — found by the 1.1.0-beta.11 parity pass, when upstream's
/// one-line change to its local-only keys led to reading the encoder. Same lesson as the watch
/// parties: when the port shares data with their client, **the bytes are the contract**.
///
/// What this enforces:
/// - Each key goes under upstream's feature, typed as upstream declares it
///   (`UpstreamSettingsManifest`, generated from their source). A typed DataStore read of a
///   wrong-typed value throws on Android, so a key whose value cannot be converted losslessly is
///   neither pushed nor imported.
/// - Keys upstream keeps on the device (engine, output layout, centre mix, …), credentials and
///   catalog layout are never sent and never applied, in either direction.
/// - Keys only this app has go under their store's feature. Android keeps keys it does not know
///   (its import writes every typed entry), so they survive its pushes.
/// - Import replaces a feature, as upstream's does: a key upstream knows, absent from a feature
///   the blob carries, goes back to its default. Keys only this app has are left alone when
///   absent, because a blob Android wrote has simply never seen them.
enum SettingsBlob {
    static let version = 1

    /// Our stores, by the name `AppSettings.syncedStores` gives them, and the feature a key of
    /// theirs belongs to unless the manifest or an alias says otherwise.
    static let storeFeature: [String: String] = [
        "app": "theme_settings",
        "player": "player_settings",
        "layout": "layout_settings",
        "debrid": "debrid_settings",
        "tracking": "trakt_settings",
        "tmdb": "tmdb_settings",
        "mdblist": "mdblist_settings",
        "skipIntro": "animeskip_settings",
        "streamBadges": "stream_badge_settings",
        "trailers": "trailer_settings",
        "trackPreference": "track_preference"
    ]

    struct Location: Hashable, Sendable {
        var feature: String
        var key: String
    }

    /// Keys stored under another name or feature than the store's default.
    static let aliases: [String: [String: Location]] = [
        "app": [
            "experience_mode": Location(feature: "experience_settings", key: "mode"),
            "experience_mode_chosen": Location(feature: "experience_settings", key: "experience_mode_chosen"),
            "startup_splash_enabled": Location(feature: "layout_settings", key: "startup_splash_enabled")
        ],
        "player": [
            // Declared upstream through a constant (`PluginDataStore.GROUP_STREAMS_BY_REPOSITORY`),
            // which the manifest generator cannot see.
            "group_streams_by_repository": Location(feature: "plugin_settings", key: "group_streams_by_repository"),
            "plugins_enabled": Location(feature: "plugin_settings", key: "plugins_enabled")
        ],
        "layout": [
            "dismissed_next_up_keys": Location(feature: "trakt_settings", key: "dismissed_next_up_keys")
        ]
    ]

    /// Types of upstream keys the generated manifest misses.
    static let extraUpstreamKeys: [String: [String: SettingsBlobType]] = [
        "plugin_settings": ["group_streams_by_repository": .boolean]
    ]

    // MARK: Exclusions — upstream's `shouldExcludePreferenceFromProfileSettingsSync`

    static let localOnlyPlayerKeys: Set<String> = [
        "player_preference", "internal_player_engine", "auto_switch_internal_player_on_error",
        "use_libass", "libass_render_type", "decoder_priority", "downmix_enabled",
        "audio_output_channels", "maintain_original_audio_on_downmix", "downmix_lfe_level",
        "downmix_normalization_enabled", "tunneling_enabled", "force_optical_passthrough",
        "audio_amplification_db", "center_mix_level_db", "night_mode", "persist_audio_amplification",
        "remember_audio_delay_per_device", "experimental_dv5_to_dv81_enabled",
        "experimental_dv7_to_dv81_preserve_mapping_enabled", "dv7_handling_mode", "map_dv7_to_hevc",
        "dv7_libdovi_mode_override", "strip_hdr10plus_sei", "exo_chapters_enabled",
        "mpv_hardware_decode_mode", "frame_rate_matching", "frame_rate_matching_mode",
        "resolution_matching_enabled", "external_player_forward_subtitles",
        "external_player_send_skip_segments", "vod_cache_enabled", "vod_cache_size_mode",
        "vod_cache_size_mb", "use_parallel_connections", "buffer_engine_enabled",
        "parallel_network_enabled", "allow_large_target_buffer", "buffer_budget_managed",
        "parallel_connection_count", "parallel_chunk_size_mb", "parallel_chunk_size_kb",
        "enable_http2", "last_playback_diagnostics_json", "enable_buffer_logs", "resize_mode",
        "min_buffer_ms", "max_buffer_ms", "buffer_for_playback_ms",
        "buffer_for_playback_after_rebuffer_ms", "target_buffer_size_mb", "back_buffer_duration_ms",
        "retain_back_buffer_from_keyframe", "nuvio_performance_mode_enabled",
        // Ours, and device-bound for the same reason: the audio route and how this Apple TV's
        // panel handles HDR are properties of the box, not of the viewer.
        "mpv_audio_output", "mpv_hdr_peak_detection"
    ]

    static let catalogKeys: Set<String> = [
        "home_catalog_order_keys", "disabled_home_catalog_keys", "custom_catalog_titles"
    ]

    static let credentialKeys: [String: Set<String>] = [
        "debrid_settings": ["torbox_api_key", "premiumize_api_key", "real_debrid_api_key"],
        "mdblist_settings": ["mdblist_api_key"],
        "animeskip_settings": ["animeskip_client_id"]
    ]

    static func isExcluded(_ location: Location) -> Bool {
        let (feature, key) = (location.feature, location.key)
        switch feature {
        case "layout_settings":
            if catalogKeys.contains(key) || key == "last_non_off_discover_location"
                || key == "search_discover_enabled" { return true }
        case "player_settings":
            if localOnlyPlayerKeys.contains(key) { return true }
        case "trailer_settings":
            if key == "trailer_allow_4k" { return true }
        case "plugin_settings":
            if key != "group_streams_by_repository" { return true }
        default:
            break
        }
        return credentialKeys[feature]?.contains(key) ?? false
    }

    // MARK: Routing

    static func location(store: String, key: String) -> Location? {
        if let alias = aliases[store]?[key] { return alias }
        guard let feature = storeFeature[store] else { return nil }
        return Location(feature: feature, key: key)
    }

    static func upstreamType(_ location: Location) -> SettingsBlobType? {
        if location.feature == "track_preference" { return trackPreferenceType(location.key) }
        return UpstreamSettingsManifest.keys[location.feature]?[location.key]
            ?? extraUpstreamKeys[location.feature]?[location.key]
    }

    /// `track_preference` keys are per title (`"<field>|<contentId>"`), so no manifest can list
    /// them; upstream's `TrackPreferenceDataStore` types them by field. Delay and speed are carried
    /// for the Android app and never read here.
    static func trackPreferenceType(_ key: String) -> SettingsBlobType? {
        guard let bar = key.firstIndex(of: "|"), key.index(after: bar) < key.endIndex else { return nil }
        switch key[..<bar] {
        case "sub_delay_ms": return .int
        case "playback_speed": return .float
        default: return .string
        }
    }

    /// The store and key a remote entry lands in.
    static func store(for location: Location) -> (store: String, key: String)? {
        for (store, keys) in aliases {
            if let match = keys.first(where: { $0.value == location }) { return (store, match.key) }
        }
        guard let store = storeFeature.first(where: { $0.value == location.feature })?.key else { return nil }
        return (store, location.key)
    }

    // MARK: Values that differ in representation

    /// Colours: `#AARRGGBB` here, a signed ARGB `Int` there (`Color.toArgb()`).
    static let colorKeys: Set<String> = [
        "subtitle_text_color", "subtitle_background_color", "subtitle_outline_color",
        "subtitle_hdr_text_color"
    ]

    /// Read here as `Double`, declared upstream as an integer of the same meaning.
    static let localDoubleKeys: Set<String> = ["subtitle_hdr_brightness", "subtitle_outline_width"]

    /// Read here as `Int`, declared upstream as a float of the same meaning.
    static let localIntKeys: Set<String> = [
        "next_episode_threshold_percent_v2", "next_episode_threshold_minutes_before_end_v2"
    ]

    /// JSON objects stored here as `Data`, carried as a JSON string.
    static let localJSONKeys: Set<String> = ["stream_badge_rules", "stream_preferences"]

    static func argb(fromHex hex: String) -> Int? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 6 { digits = "FF" + digits }
        guard digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        return Int(Int32(bitPattern: value))
    }

    static func hex(fromARGB argb: Int) -> String {
        String(format: "#%08X", UInt32(truncatingIfNeeded: argb))
    }

    // MARK: Encode

    /// Stored values come back from `UserDefaults` as `NSNumber`, where `as? Bool` accepts a 1
    /// and `as? Int` accepts a 2.0. The CoreFoundation type is the only honest answer.
    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func isFloatingPoint(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, !isBoolean(value) else { return false }
        return CFNumberIsFloatType(number)
    }

    static func integer(_ value: Any) -> Int? {
        guard !isBoolean(value), !isFloatingPoint(value) else { return nil }
        return (value as? NSNumber)?.intValue ?? (value as? Int)
    }

    static func floating(_ value: Any) -> Double? {
        guard !isBoolean(value) else { return nil }
        return (value as? NSNumber)?.doubleValue ?? (value as? Double)
    }

    /// One `{type, value}` entry, or nil when the value cannot be carried as `type`.
    static func encode(_ value: Any, key: String, as type: SettingsBlobType?) -> AnyJSONValue? {
        func entry(_ type: SettingsBlobType, _ value: AnyJSONValue) -> AnyJSONValue {
            .object(["type": .string(type.rawValue), "value": value])
        }
        guard let type else { return natural(value) }
        switch type {
        case .boolean:
            guard isBoolean(value), let bool = value as? Bool else { return nil }
            return entry(.boolean, .bool(bool))
        case .int, .long:
            if colorKeys.contains(key), let string = value as? String {
                return argb(fromHex: string).map { entry(type, .int($0)) }
            }
            if let int = integer(value) { return entry(type, .int(int)) }
            if let double = floating(value), double.rounded() == double, abs(double) < 2e9 {
                return entry(type, .int(Int(double)))
            }
            return nil
        case .float, .double:
            return floating(value).map { entry(type, .double($0)) }
        case .string:
            if let string = value as? String { return entry(.string, .string(string)) }
            if let data = value as? Data, let json = String(data: data, encoding: .utf8) {
                return entry(.string, .string(json))
            }
            return nil
        case .stringSet:
            return (value as? [String]).map { entry(.stringSet, .array($0.sorted().map(AnyJSONValue.string))) }
        }
    }

    /// Keys only this app has: typed by what they hold.
    private static func natural(_ value: Any) -> AnyJSONValue? {
        func entry(_ type: SettingsBlobType, _ value: AnyJSONValue) -> AnyJSONValue {
            .object(["type": .string(type.rawValue), "value": value])
        }
        if isBoolean(value), let bool = value as? Bool { return entry(.boolean, .bool(bool)) }
        if let int = integer(value) { return entry(.int, .int(int)) }
        if let double = floating(value) { return entry(.double, .double(double)) }
        switch value {
        case let string as String: return entry(.string, .string(string))
        case let list as [String]: return entry(.stringSet, .array(list.sorted().map(AnyJSONValue.string)))
        case let data as Data:
            return String(data: data, encoding: .utf8).map { entry(.string, .string($0)) }
        default: return nil
        }
    }

    /// The whole blob, from each store's stored values (secrets already left out).
    ///
    /// - Parameter remote: the row as last pulled. Its entries for keys this app does not hold
    ///   are carried over: a push replaces the row, and Android's import clears each feature it
    ///   receives, so anything dropped here would reset on the Android app — its own settings,
    ///   and the device-local ones it deliberately keeps out of our reach.
    static func export(
        _ stores: [String: [String: Any]], preserving remote: [String: AnyJSON]? = nil
    ) -> [String: AnyJSONValue] {
        var features: [String: [String: AnyJSONValue]] = [:]
        if let remote, case .object(let remoteFeatures)? = remote["features"] {
            for (feature, payload) in remoteFeatures {
                guard case .object(let entries) = payload else { continue }
                for (key, value) in entries {
                    features[feature, default: [:]][key] = value.jsonValue
                }
            }
        }
        for (store, values) in stores {
            for (key, value) in values {
                guard let location = location(store: store, key: key), !isExcluded(location) else { continue }
                let known = upstreamType(location)
                // A key upstream declares with an incompatible type is skipped, not guessed.
                guard let encoded = encode(value, key: key, as: known) else { continue }
                features[location.feature, default: [:]][location.key] = encoded
            }
        }
        return [
            "version": .int(version),
            "features": .object(features.mapValues { .object($0) })
        ]
    }

    // MARK: Decode

    /// What applying a blob does to one store.
    struct StoreChange: Equatable {
        var set: [String: SettingValue] = [:]
        var remove: Set<String> = []
    }

    /// A value in the Swift type the store reads it as.
    enum SettingValue: Equatable {
        case bool(Bool), int(Int), double(Double), string(String), strings([String]), data(Data)

        var raw: Any {
            switch self {
            case .bool(let v): return v
            case .int(let v): return v
            case .double(let v): return v
            case .string(let v): return v
            case .strings(let v): return v
            case .data(let v): return v
            }
        }
    }

    /// Whether a pulled blob is in this shape. The old one (`{player: {…}}`) has no `features`.
    static func isCurrentShape(_ blob: [String: AnyJSON]) -> Bool {
        if case .object? = blob["features"] { return true }
        return false
    }

    /// - Parameter local: each store's stored values, to find what a present feature no longer
    ///   carries.
    static func changes(
        from blob: [String: AnyJSON], local: [String: [String: Any]]
    ) -> [String: StoreChange] {
        guard case .object(let features)? = blob["features"] else { return [:] }
        var out: [String: StoreChange] = [:]

        for (feature, payload) in features {
            guard case .object(let entries) = payload else { continue }
            for (key, encoded) in entries {
                let location = Location(feature: feature, key: key)
                guard !isExcluded(location), let target = store(for: location),
                      let value = decode(encoded, localKey: target.key, upstreamType: upstreamType(location))
                else { continue }
                out[target.store, default: StoreChange()].set[target.key] = value
            }
        }

        // Replace semantics: an upstream-known key absent from a feature the blob carries.
        for (store, values) in local {
            for key in values.keys {
                guard let location = location(store: store, key: key), !isExcluded(location),
                      upstreamType(location) != nil,
                      case .object(let entries)? = features[location.feature],
                      entries[location.key] == nil,
                      encode(values[key] as Any, key: key, as: upstreamType(location)) != nil
                else { continue }
                out[store, default: StoreChange()].remove.insert(key)
            }
        }
        return out
    }

    static func decode(
        _ encoded: AnyJSON, localKey: String, upstreamType known: SettingsBlobType?
    ) -> SettingValue? {
        guard case .object(let entry) = encoded,
              case .string(let typeName)? = entry["type"],
              let type = SettingsBlobType(rawValue: typeName),
              let value = entry["value"]
        else { return nil }
        // A remote type that contradicts the declared one is somebody else's bug; not applied.
        if let known, known != type, !(compatible(known, type)) { return nil }

        switch (type, value) {
        case (.boolean, .bool(let bool)): return .bool(bool)
        case (.boolean, .string(let string)):
            return string == "true" ? .bool(true) : string == "false" ? .bool(false) : nil
        case (.int, .number(let number)), (.long, .number(let number)):
            guard number.rounded() == number else { return nil }
            if colorKeys.contains(localKey) { return .string(hex(fromARGB: Int(number))) }
            if localDoubleKeys.contains(localKey) { return .double(number) }
            return .int(Int(number))
        case (.float, .number(let number)), (.double, .number(let number)):
            if localIntKeys.contains(localKey) { return .int(Int(number.rounded())) }
            return .double(number)
        case (.string, .string(let string)):
            if localJSONKeys.contains(localKey) {
                guard let data = string.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
                return .data(data)
            }
            return .string(string)
        case (.stringSet, .array(let items)):
            let strings = items.compactMap { item -> String? in
                if case .string(let s) = item { return s }
                return nil
            }
            return strings.count == items.count ? .strings(strings) : nil
        default:
            return nil
        }
    }

    private static func compatible(_ a: SettingsBlobType, _ b: SettingsBlobType) -> Bool {
        let integral: Set<SettingsBlobType> = [.int, .long]
        let floating: Set<SettingsBlobType> = [.float, .double]
        return (integral.contains(a) && integral.contains(b)) || (floating.contains(a) && floating.contains(b))
    }

    // MARK: The old shape

    /// `{app: {key: value}, player: {…}}`, as this app wrote before 1.0.58. Read once so an
    /// account used only on Apple TVs keeps its settings; the next push writes the new shape.
    static func legacyChanges(from blob: [String: AnyJSON]) -> [String: [String: AnyJSON]] {
        var out: [String: [String: AnyJSON]] = [:]
        for store in storeFeature.keys {
            guard case .object(let values)? = blob[store] else { continue }
            out[store] = values.filter { key, _ in
                guard let location = location(store: store, key: key) else { return false }
                return !isExcluded(location)
            }
        }
        return out
    }
}

extension AnyJSON {
    /// The same JSON, in the type the backend client encodes.
    var jsonValue: AnyJSONValue {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value):
            return value.rounded() == value && abs(value) < 9e15 ? .int(Int(value)) : .double(value)
        case .bool(let value): return .bool(value)
        case .object(let value): return .object(value.mapValues(\.jsonValue))
        case .array(let value): return .array(value.map(\.jsonValue))
        case .null: return .null
        }
    }
}
