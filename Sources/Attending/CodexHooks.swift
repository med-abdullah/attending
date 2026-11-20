import Foundation

/// Connects Codex's approvals to the notch: adds the bridge as Codex's PermissionRequest
/// hook in ~/.codex/hooks.json. Codex sessions are already followed through their
/// rollout files, so this is the only hook needed. Other hooks are kept, the first
/// original is backed up, and Codex itself asks the user to trust the new hook once
/// before it runs; Attending never marks it trusted.
@MainActor enum CodexHooks {
    static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true) }
    static var hooksURL: URL { folder.appendingPathComponent("hooks.json") }
    /// Codex has been used on this Mac.
    static var codexInstalled: Bool { FileManager.default.fileExists(atPath: folder.path) }
    static let wait = 60

    static func command(bridge: String) -> String { ClaudeHooks.quote(bridge) + " --codex --approval-wait \(wait)" }

    static var installed: Bool {
        guard let bridge = ClaudeHooks.bridge, let data = try? Data(contentsOf: hooksURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        let wanted = command(bridge: bridge.path)
        return (hooks["PermissionRequest"] as? [[String: Any]] ?? []).contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == wanted }
        }
    }

    @discardableResult
    static func install() throws -> String {
        guard let bridge = ClaudeHooks.bridge else { throw ClaudeHooks.Failure.message("The bridge is missing from this copy of Attending.") }
        guard MoveToApplications.isInApplications(Bundle.main.bundleURL) || Bundle.main.bundleIdentifier != Updater.publicBundleID else {
            throw ClaudeHooks.Failure.message("Move Attending to Applications first, so Codex can always find it.")
        }
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: hooksURL.path)) != nil { throw ClaudeHooks.Failure.message("Codex's hooks file is a link, so Attending left it alone.") }
        let raw = try? Data(contentsOf: hooksURL)
        var settings: [String: Any] = [:]
        if let raw, !raw.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw ClaudeHooks.Failure.message("Codex's hooks.json couldn't be read, so nothing was changed.") }
            settings = parsed
        }
        settings = try merged(settings, bridge: bridge.path)
        let encoded = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let raw {
            let backup = hooksURL.appendingPathExtension("attending-backup")
            if !fm.fileExists(atPath: backup.path) { fm.createFile(atPath: backup.path, contents: raw, attributes: [.posixPermissions: 0o600]) }
        }
        guard (try? Data(contentsOf: hooksURL)) == raw else { throw ClaudeHooks.Failure.message("Codex's hooks changed while connecting. Try again.") }
        try encoded.write(to: hooksURL, options: .atomic)
        return "Connected. The next time Codex starts, it asks you to trust the new hook once (in the CLI, type /hooks). Approvals then show in the notch."
    }

    static func merged(_ settings: [String: Any], bridge: String) throws -> [String: Any] {
        var result = settings
        if let existing = result["hooks"], !(existing is [String: Any]) { throw ClaudeHooks.Failure.message("Codex's hooks aren't in the expected shape, so nothing was changed.") }
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        let selected = command(bridge: bridge)
        guard var entries = (hooks["PermissionRequest"] ?? [[String: Any]]()) as? [[String: Any]] else {
            throw ClaudeHooks.Failure.message("Codex's PermissionRequest hooks aren't in the expected shape, so nothing was changed.")
        }
        // Drop only Attending's own entries that point elsewhere (an older copy); keep the rest.
        entries = entries.compactMap { group in
            var group = group
            let kept = (group["hooks"] as? [[String: Any]] ?? []).filter { hook in
                let text = hook["command"] as? String ?? ""
                return !(text.contains("attending-bridge") && text != selected)
            }
            group["hooks"] = kept
            return kept.isEmpty ? nil : group
        }
        let present = entries.contains { ($0["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == selected } }
        if !present {
            entries.append(["hooks": [["type": "command", "command": selected, "timeout": wait + 5, "statusMessage": "Waiting for an answer in Attending"]]])
        }
        hooks["PermissionRequest"] = entries
        result["hooks"] = hooks
        return result
    }
}
