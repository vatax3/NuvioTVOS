import Foundation

/// A change a phone has asked for and the television has not yet agreed to.
///
/// The page is served to anything on the local network. Adding a plugin repository installs code
/// that then runs against every stream request, so a page that could do it unattended would be a
/// hole — whoever is holding the remote has to agree. Upstream draws the same line with its
/// `PendingRepoChange`, and it is the reason this type exists rather than the handler simply
/// calling the store.
struct RepositoryConfigChange: Identifiable, Equatable {
    enum Kind: Equatable {
        case add(url: String)
        case remove(id: String, name: String)
        case setEnabled(id: String, name: String, enabled: Bool)
    }

    var id = UUID().uuidString
    var kind: Kind

    /// What the television asks the viewer, phrased as the thing that will happen.
    var prompt: String {
        switch kind {
        case .add(let url):
            return "Add the plugin repository at \(url)?"
        case .remove(_, let name):
            return "Remove \(name) and its scrapers?"
        case .setEnabled(_, let name, let enabled):
            return enabled ? "Turn \(name) back on?" : "Turn \(name) off?"
        }
    }

    /// The detail line. Adding is the one that deserves a warning: it is the only case that
    /// brings new code onto the device.
    var caution: String? {
        switch kind {
        case .add:
            return """
            A device on your network asked for this. Plugin repositories run their own code to \
            find streams — only add ones you trust.
            """
        case .remove:
            return "A device on your network asked for this."
        case .setEnabled:
            return nil
        }
    }

    /// What the phone is told while it waits, and what it is told afterwards.
    var pendingNotice: String {
        switch kind {
        case .add: return "Waiting for the Apple TV to confirm adding that repository."
        case .remove: return "Waiting for the Apple TV to confirm the removal."
        case .setEnabled: return "Waiting for the Apple TV to confirm the change."
        }
    }

    func settledNotice(approved: Bool) -> String {
        guard approved else { return "The Apple TV declined that change." }
        switch kind {
        case .add: return "Repository added."
        case .remove: return "Repository removed."
        case .setEnabled(_, _, let enabled): return enabled ? "Turned back on." : "Turned off."
        }
    }
}

enum RepositoryConfigRequest {
    /// Reads a form post into a change, or nothing.
    ///
    /// Returning nil rather than throwing for an unknown action is deliberate: the page is the
    /// only thing that posts here, so an action it did not send is a stale tab or a probe, and
    /// neither deserves a prompt on the television.
    static func change(
        from fields: [String: String],
        known repositories: [(id: String, name: String, isEnabled: Bool)]
    ) -> RepositoryConfigChange? {
        let action = fields["action"] ?? ""
        let identifier = fields["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch action {
        case "add":
            let url = fields["url"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty else { return nil }
            return RepositoryConfigChange(kind: .add(url: url))
        case "remove":
            guard let match = repositories.first(where: { $0.id == identifier }) else { return nil }
            return RepositoryConfigChange(kind: .remove(id: match.id, name: match.name))
        case "toggle":
            guard let match = repositories.first(where: { $0.id == identifier }) else { return nil }
            return RepositoryConfigChange(
                kind: .setEnabled(id: match.id, name: match.name, enabled: !match.isEnabled)
            )
        default:
            return nil
        }
    }
}
