import Foundation

/// Adds MeetMouse's stdio MCP helper to Claude Desktop's config file.
/// Claude's "Add custom connector" dialog only takes remote HTTPS URLs, so a
/// local stdio server has to be listed in claude_desktop_config.json instead.
/// The merge is a pure function (testable); `install` is the thin file layer.
enum ClaudeDesktopConfig {
    enum Status: Equatable {
        case added            // no meetmouse entry before
        case updated          // entry existed but pointed elsewhere
        case alreadyAdded     // entry already points at this helper
    }

    enum ConfigError: Error, Equatable {
        case invalidJSON      // existing file is not a JSON object
        case badServers       // "mcpServers" exists but is not an object
    }

    static let serverKey = "meetmouse"

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// Pretty JSON snippet for hosts we can't edit for the user.
    static func snippet(helperPath: String) -> String {
        let obj: [String: Any] = ["mcpServers": [serverKey: ["command": helperPath]]]
        let data = (try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Merge our entry into existing config bytes (nil/empty = no file yet).
    /// Only `mcpServers.meetmouse` is touched; everything else is preserved.
    static func merge(existing: Data?, helperPath: String) throws -> (Data, Status) {
        var root: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                throw ConfigError.invalidJSON
            }
            root = parsed
        }
        var servers: [String: Any] = [:]
        if let raw = root["mcpServers"] {
            guard let dict = raw as? [String: Any] else { throw ConfigError.badServers }
            servers = dict
        }
        let status: Status
        if let entry = servers[serverKey] as? [String: Any],
           entry["command"] as? String == helperPath {
            status = .alreadyAdded
        } else if servers[serverKey] != nil {
            status = .updated
        } else {
            status = .added
        }
        if status != .alreadyAdded {
            // Replace wholesale: stale args/env from an old entry would break the new path.
            servers[serverKey] = ["command": helperPath]
        }
        root["mcpServers"] = servers
        let out = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        return (out, status)
    }

    static let installedHelperPath = "/Applications/MeetMouse.app/Contents/MacOS/meetmouse-mcp"

    enum HelperChoice: Equatable {
        case use(String)
        case useDev(String)   // dev/build path; caller should note it
        case refuse           // translocated with no /Applications copy
    }

    /// Pure: which helper path is safe to write into the config.
    static func chooseHelperPath(bundled: String, installedExists: Bool, isDebug: Bool) -> HelperChoice {
        if installedExists { return .use(installedHelperPath) }
        if bundled.contains("/AppTranslocation/") { return .refuse }
        if isDebug || bundled.contains("/DerivedData/") || bundled.contains("/Build/Products/") {
            return isDebug ? .useDev(bundled) : .refuse
        }
        return .use(bundled)
    }

    /// Reads, merges, backs up once, and writes atomically. Throws
    /// `ConfigError.invalidJSON` without touching the file if it is unreadable JSON.
    @discardableResult
    static func install(helperPath: String, at configLocation: URL = configURL) throws -> Status {
        let fm = FileManager.default
        // Follow a symlinked config (dotfiles setups) so the link survives the atomic write.
        let url = configLocation.resolvingSymlinksInPath()
        let existing = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let (data, status) = try merge(existing: existing, helperPath: helperPath)
        if status == .alreadyAdded { return status }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing {
            let backup = url.appendingPathExtension("meetmouse-backup")
            if !fm.fileExists(atPath: backup.path) { try existing.write(to: backup, options: .atomic) }
        }
        try data.write(to: url, options: .atomic)
        return status
    }
}
