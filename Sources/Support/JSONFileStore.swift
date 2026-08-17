import Foundation
import os

/// Small Codable-on-disk helper used by the stores. Writes are atomic and debounced by the
/// callers, reads are synchronous at launch so the first frame already has real data.
struct JSONFileStore<Value: Codable> {
    private let url: URL
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "JSONFileStore")

    /// `global` files (the profile list itself) live at the top level; everything else is
    /// scoped to the active profile so each one keeps its own library and progress.
    init(filename: String, scope: ProfileScope.Storage = .profile) {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        var directory = base.appendingPathComponent("Nuvio", isDirectory: true)
        if case .profile = scope, let subdirectory = ProfileScope.storageSubdirectory {
            directory = directory.appendingPathComponent(subdirectory, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(filename)
    }

    func load() -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            log.error("Failed reading \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ value: Value) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Failed writing \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
