import Foundation

@main
struct ClaudeDesktopCheck {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "  ok  \(name)" : "  FAIL \(name)")
        if !ok { failures += 1 }
    }
    static func obj(_ d: Data) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: d)) as! [String: Any]
    }
    static func command(_ d: Data) -> String? {
        ((obj(d)["mcpServers"] as? [String: Any])?["meetmouse"] as? [String: Any])?["command"] as? String
    }

    static func main() throws {
        let p = "/Applications/MeetMouse.app/Contents/MacOS/meetmouse-mcp"

        var (d, s) = try ClaudeDesktopConfig.merge(existing: nil, helperPath: p)
        check(s == .added && command(d) == p, "no file -> creates entry")
        (d, s) = try ClaudeDesktopConfig.merge(existing: Data(" \n".utf8), helperPath: p)
        check(s == .added && command(d) == p, "blank file -> creates entry")

        let rich = #"{"theme":"dark","mcpServers":{"other":{"command":"x","args":["a"],"env":{"K":"V"}}}}"#
        (d, s) = try ClaudeDesktopConfig.merge(existing: Data(rich.utf8), helperPath: p)
        let o = obj(d)
        let other = (o["mcpServers"] as! [String: Any])["other"] as! [String: Any]
        check(s == .added && o["theme"] as? String == "dark"
              && other["command"] as? String == "x" && other["args"] as? [String] == ["a"]
              && (other["env"] as? [String: String]) == ["K": "V"],
              "preserves other keys and servers")

        let (d2, s2) = try ClaudeDesktopConfig.merge(existing: d, helperPath: p)
        check(s2 == .alreadyAdded && obj(d2)["theme"] as? String == "dark", "same path -> alreadyAdded")

        (d, s) = try ClaudeDesktopConfig.merge(existing: d, helperPath: "/new/meetmouse-mcp")
        check(s == .updated && command(d) == "/new/meetmouse-mcp", "different path -> updated")

        let legacy = #"{"mcpServers":{"meetingcoach":{"command":"/old"},"meetmouse":{"command":"/old2","args":["z"]}}}"#
        (d, s) = try ClaudeDesktopConfig.merge(existing: Data(legacy.utf8), helperPath: p)
        let sv = obj(d)["mcpServers"] as! [String: Any]
        check(s == .updated && command(d) == p && sv["meetingcoach"] != nil, "legacy key left alone, meetmouse updated")

        for bad in ["{not json", "[1,2]", "\"str\""] {
            do { _ = try ClaudeDesktopConfig.merge(existing: Data(bad.utf8), helperPath: p)
                 check(false, "invalid JSON throws: \(bad)") }
            catch { check(error as? ClaudeDesktopConfig.ConfigError == .invalidJSON, "invalid JSON throws: \(bad)") }
        }
        do { _ = try ClaudeDesktopConfig.merge(existing: Data(#"{"mcpServers":[]}"#.utf8), helperPath: p)
             check(false, "non-object mcpServers throws") }
        catch { check(error as? ClaudeDesktopConfig.ConfigError == .badServers, "non-object mcpServers throws") }

        // File layer on a temp dir only.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cdc-\(UUID().uuidString)/Claude")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let url = dir.appendingPathComponent("claude_desktop_config.json")
        check(try ClaudeDesktopConfig.install(helperPath: p, at: url) == .added, "install creates dir + file")
        check(!FileManager.default.fileExists(atPath: url.path + ".meetmouse-backup"), "no backup when no prior file")
        let orig = #"{"keep":1}"#
        try Data(orig.utf8).write(to: url)
        _ = try ClaudeDesktopConfig.install(helperPath: p, at: url)
        let backup = url.appendingPathExtension("meetmouse-backup")
        check(String(data: try Data(contentsOf: backup), encoding: .utf8) == orig, "backup holds original")
        _ = try ClaudeDesktopConfig.install(helperPath: "/other", at: url)
        check(String(data: try Data(contentsOf: backup), encoding: .utf8) == orig, "backup written only once")
        try Data("{broken".utf8).write(to: url)
        do { _ = try ClaudeDesktopConfig.install(helperPath: p, at: url); check(false, "install refuses invalid file") }
        catch { check(String(data: try Data(contentsOf: url), encoding: .utf8) == "{broken", "install refuses invalid file, untouched") }

        // Symlinked config stays a symlink; the target gets the edit.
        let sdir = FileManager.default.temporaryDirectory.appendingPathComponent("cdc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sdir) }
        try FileManager.default.createDirectory(at: sdir, withIntermediateDirectories: true)
        let target = sdir.appendingPathComponent("dotfiles.json")
        let link = sdir.appendingPathComponent("claude_desktop_config.json")
        try Data(#"{"keep":1}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = try ClaudeDesktopConfig.install(helperPath: p, at: link)
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
        let tdata = try Data(contentsOf: target)
        check(isLink && command(tdata) == p, "symlinked config stays linked, target updated")
        check(FileManager.default.fileExists(atPath: target.path + ".meetmouse-backup")
              && !FileManager.default.fileExists(atPath: link.path + ".meetmouse-backup"), "backup sits next to the real file")

        // Unchanged entry -> file not rewritten.
        let before = try Data(contentsOf: target)
        let attrs0 = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as! Date
        Thread.sleep(forTimeInterval: 1.1)
        let st = try ClaudeDesktopConfig.install(helperPath: p, at: link)
        let attrs1 = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as! Date
        let after = try Data(contentsOf: target)
        check(st == .alreadyAdded && attrs1 == attrs0 && after == before, "already-correct entry does not rewrite file")

        // Helper path choice.
        let inst = ClaudeDesktopConfig.installedHelperPath
        let tr = "/private/var/folders/x/AppTranslocation/ABC/d/MeetMouse.app/Contents/MacOS/meetmouse-mcp"
        let dbg = "/Users/u/Library/Developer/Xcode/DerivedData/MC/Build/Products/Debug/MeetMouse.app/Contents/MacOS/meetmouse-mcp"
        typealias C = ClaudeDesktopConfig
        check(C.chooseHelperPath(bundled: tr, installedExists: true, isDebug: false) == .use(inst), "translocated + /Applications copy -> /Applications")
        check(C.chooseHelperPath(bundled: tr, installedExists: false, isDebug: false) == .refuse, "translocated, no copy -> refuse")
        check(C.chooseHelperPath(bundled: dbg, installedExists: true, isDebug: true) == .use(inst), "debug + /Applications copy -> /Applications")
        check(C.chooseHelperPath(bundled: dbg, installedExists: false, isDebug: true) == .useDev(dbg), "debug, no copy -> dev path flagged")
        check(C.chooseHelperPath(bundled: dbg, installedExists: false, isDebug: false) == .refuse, "release build in DerivedData -> refuse")
        check(C.chooseHelperPath(bundled: inst, installedExists: false, isDebug: false) == .use(inst), "normal /Applications path used as-is")

        print(failures == 0 ? "claude-desktop: PASS" : "claude-desktop: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
