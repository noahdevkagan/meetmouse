// ax-probe.swift - dev-only, read-only Accessibility (AXUIElement) probe.
// NOT part of the MeetMouse app target. See scripts/ax-probe.md.
//
//   swift scripts/ax-probe.swift <zoom|teams|chrome|safari|bundle-id>
//        [--seconds 60] [--interval 1] [--out DIR] [--redact]
//        [--max-nodes 4000] [--max-depth 50] [--no-enable]
//
// Passive: it only reads attributes. The single exception is the two
// accessibility-enable flags (AXManualAccessibility, AXEnhancedUserInterface)
// set on Chromium browsers, Teams and unknown bundle ids, restored on exit.
// No clicks, presses, focus changes or network access.

import Cocoa
import ApplicationServices

// MARK: - Options

struct Options {
    var target = ""
    var seconds = 60.0
    var interval = 1.0
    var out: String?
    var redact = false
    var maxNodes = 4000
    var maxDepth = 50
    var noEnable = false
}

func fail(_ msg: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func usage() -> Never {
    fail("""
    usage: swift scripts/ax-probe.swift <zoom|teams|chrome|safari|bundle-id> [options]
      --seconds N      total run time (default 60)
      --interval N     seconds between tree walks (default 1)
      --out DIR        output directory (default: new dir under /tmp; never inside the repo)
      --redact         replace text values with a short hash plus length
      --max-nodes N    node cap per walk (default 4000)
      --max-depth N    depth cap per walk (default 50)
      --no-enable      do not set the accessibility-enable flags
    """)
}

func dbl(_ s: String) -> Double { guard let v = Double(s) else { usage() }; return v }
func int(_ s: String) -> Int { guard let v = Int(s) else { usage() }; return v }

func parseOptions() -> Options {
    var o = Options()
    var a = Array(CommandLine.arguments.dropFirst())
    // `swift script.swift args` may include the script path first in some setups.
    if let f = a.first, f.hasSuffix("ax-probe.swift") { a.removeFirst() }
    var i = 0
    func next() -> String { i += 1; if i >= a.count { usage() }; return a[i] }
    while i < a.count {
        switch a[i] {
        case "--seconds": o.seconds = dbl(next())
        case "--interval": o.interval = dbl(next())
        case "--out": o.out = next()
        case "--redact": o.redact = true
        case "--max-nodes": o.maxNodes = int(next())
        case "--max-depth": o.maxDepth = int(next())
        case "--no-enable": o.noEnable = true
        case "-h", "--help": usage()
        default:
            if a[i].hasPrefix("--") || !o.target.isEmpty { usage() }
            o.target = a[i]
        }
        i += 1
    }
    if o.target.isEmpty || o.interval <= 0 || o.seconds <= 0 { usage() }
    return o
}

let opts = parseOptions()

// MARK: - Step 1: trust check (never prompts)

if !AXIsProcessTrusted() {
    let term = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "your terminal app"
    fail("""
    ax-probe: this process is not trusted for Accessibility, so it cannot read other apps' windows.

    Grant it to the app that is running this command (detected: \(term)):
      1. Open System Settings > Privacy & Security > Accessibility.
      2. Click +, add \(term) (or switch it on if already listed).
      3. Quit \(term) completely (Cmd-Q) and reopen it, then run this command again.
    Shortcut: open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    Not prompting. Exiting.
    """, code: 2)
}

// MARK: - Redaction

let salt = UInt64.random(in: 1...UInt64.max)
let statusVocab = ["unmuted", "muted", "speaking", "talking", "presenting", "presenter", "co-host", "host",
                   "pinned", "spotlight", "raised hand", "hand raised", "camera on", "camera off",
                   "video on", "video off", "active speaker", "screen sharing", "sharing", "captions", "you"]

func statusTags(_ s: String) -> [String] {
    var l = s.lowercased()
    var tags: [String] = []
    if l.contains("unmuted") { tags.append("unmuted"); l = l.replacingOccurrences(of: "unmuted", with: "") }
    for w in statusVocab where w != "unmuted" && l.contains(w) { if !(w == "host" && tags.contains("co-host")) { tags.append(w) } }
    return tags
}

func redact(_ s: String) -> String {
    if s.isEmpty { return s }
    var h: UInt64 = 0xcbf29ce484222325 ^ salt
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    let tags = statusTags(s)
    return String(format: "h:%06llx#%d", h & 0xffffff, s.count) + (tags.isEmpty ? "" : "[" + tags.joined(separator: ",") + "]")
}

/// Text attributes get redacted; identifier/DOM id/class names are structural and kept.
func shown(_ key: String, _ v: String) -> String {
    guard opts.redact else { return v }
    let keep: Set<String> = ["role", "subrole", "roleDescription", "identifier", "frame", "selected", "focused", "enabled", "_attrNames"]
    if keep.contains(key) || key.contains("DOMClass") || key.contains("DOMIdentifier") { return v }
    if Double(v) != nil || v == "true" || v == "false" { return v }
    return redact(v)
}

// MARK: - Process helpers

func allPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    if n <= 0 { return [] }
    var buf = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    return Array(buf.prefix(Int(max(got, 0)))).filter { $0 > 0 }
}

func pidPath(_ pid: pid_t) -> String? {
    var b = [CChar](repeating: 0, count: 4096)
    let r = proc_pidpath(pid, &b, UInt32(b.count))
    return r > 0 ? String(cString: b) : nil
}

func pids(inBundle path: String) -> [pid_t] {
    allPids().filter { (pidPath($0) ?? "").hasPrefix(path + "/") }
}

let tbase: (Double, Double) = {
    var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
    return (Double(t.numer), Double(t.denom))
}()

func cpuSeconds(_ pid: pid_t) -> Double? {
    var ti = proc_taskinfo()
    let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
    if r <= 0 { return nil }
    return Double(ti.pti_total_user + ti.pti_total_system) * tbase.0 / tbase.1 / 1e9
}

func cpuSnapshot(_ ps: [pid_t]) -> [pid_t: Double] {
    var d: [pid_t: Double] = [:]
    for p in ps { if let c = cpuSeconds(p) { d[p] = c } }
    return d
}

/// Percent of one core, summed over processes present in both snapshots.
func cpuPercent(_ a: [pid_t: Double], _ b: [pid_t: Double], over secs: Double) -> Double {
    var delta = 0.0
    for (p, c) in b { if let c0 = a[p] { delta += max(0, c - c0) } }
    return secs > 0 ? delta / secs * 100 : 0
}

func selfCPU() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(u.ru_utime) + s(u.ru_stime)
}

// MARK: - AX helpers

func axCopy(_ el: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return (e, v)
}

func simplify(_ v: CFTypeRef, depth: Int = 0) -> String? {
    let t = CFGetTypeID(v)
    if t == CFStringGetTypeID() { return (v as! CFString) as String }
    if t == CFBooleanGetTypeID() { return CFBooleanGetValue((v as! CFBoolean)) ? "true" : "false" }
    if t == CFNumberGetTypeID() { return (v as! NSNumber).stringValue }
    if t == CFURLGetTypeID() { return (v as! CFURL as URL).absoluteString }
    if t == AXValueGetTypeID() {
        let av = unsafeBitCast(v, to: AXValue.self)
        switch AXValueGetType(av) {
        case .cgPoint: var p = CGPoint.zero; AXValueGetValue(av, .cgPoint, &p); return "\(Int(p.x)),\(Int(p.y))"
        case .cgSize: var s = CGSize.zero; AXValueGetValue(av, .cgSize, &s); return "\(Int(s.width)),\(Int(s.height))"
        case .cgRect: var r = CGRect.zero; AXValueGetValue(av, .cgRect, &r); return "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
        case .cfRange: var r = CFRange(); AXValueGetValue(av, .cfRange, &r); return "\(r.location)+\(r.length)"
        default: return nil
        }
    }
    if t == CFArrayGetTypeID(), depth == 0 {
        let arr = v as! CFArray
        var parts: [String] = []
        for i in 0..<min(CFArrayGetCount(arr), 20) {
            guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
            let el = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard let s = simplify(el, depth: 1) else { return nil }
            parts.append(s)
        }
        return parts.joined(separator: " ")
    }
    return nil
}

func truncated(_ s: String, _ n: Int = 200) -> String { s.count > n ? String(s.prefix(n)) + "..." : s }

// Standard attributes mapped to short keys; structural/element-valued ones are never recorded.
let standardMap: [String: String] = [
    "AXRole": "role", "AXSubrole": "subrole", "AXTitle": "title", "AXDescription": "description",
    "AXValue": "value", "AXIdentifier": "identifier", "AXRoleDescription": "roleDescription",
    "AXSelected": "selected", "AXFocused": "focused", "AXEnabled": "enabled", "AXHelp": "help",
]
let framePieces: Set<String> = ["AXPosition", "AXSize", "AXFrame"]
let structural: Set<String> = ["AXChildren", "AXParent", "AXWindow", "AXTopLevelUIElement"]

// MARK: - Tree model

final class Node {
    var id = ""
    var path = ""
    var attrs: [String: String] = [:]      // display (possibly redacted) values
    var raw: [String: String] = [:]        // unredacted text, memory only, used for summary matching
    var children: [Node] = []
    var json: [String: Any] {
        var d: [String: Any] = ["id": id, "path": path, "attrs": attrs]
        if !children.isEmpty { d["children"] = children.map { $0.json } }
        return d
    }
}

struct Ctx { var inList = false; var caption = false; var participant = false }

struct Tick {
    var roots: [Node] = []
    var flat: [String: Node] = [:]
    var capped: Set<String> = []
    var nodeCount = 0
    var seconds = 0.0
}

let captionWords = ["caption", "subtitle", "transcript"]
let participantWords = ["participant", "attendee", "roster", "people", "in this meeting", "in this call", "in the meeting"]
let uiStop: Set<String> = ["mute", "unmute", "share", "chat", "participants", "leave", "end", "more", "video", "stop video",
                           "start video", "record", "reactions", "apps", "whiteboards", "settings", "view", "security",
                           "raise hand", "people", "captions", "meeting info", "close", "minimize", "back", "send", "cancel", "ok"]

final class Collector {
    var labelCands: [String: Int] = [:]      // "kind | role | label"
    var statusHits: [String: Int] = [:]      // "role.attr [tags] sample"
    var captionHits: [String: Int] = [:]
    var flipStats: [String: (changes: Int, values: Set<String>, role: String, attr: String)] = [:]
    var attrChangeCounts: [String: Int] = [:]
    var changedNodes = Set<String>()
    var totalChangeEvents = 0
    var maxNodesSeen = 0
    var cappedTicks = 0
    var ticks = 0
}
let col = Collector()

func containsAny(_ s: String, _ words: [String]) -> Bool {
    let l = s.lowercased(); return words.contains { l.contains($0) }
}

func looksLikeName(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count < 2 || t.count > 40 { return false }
    if t.split(separator: " ").count > 5 { return false }
    if !t.contains(where: { $0.isLetter }) { return false }
    return !uiStop.contains(t.lowercased())
}

final class Walker {
    let maxNodes: Int, maxDepth: Int, deadline: Date
    var tick = Tick()
    init(maxNodes: Int, maxDepth: Int, deadline: Date) { self.maxNodes = maxNodes; self.maxDepth = maxDepth; self.deadline = deadline }

    func walk(_ el: AXUIElement, parentPath: String, index: Int, depth: Int, ctx: Ctx, pid: pid_t) -> Node? {
        if tick.nodeCount >= maxNodes { tick.capped.insert("nodes"); return nil }
        if Date() > deadline { tick.capped.insert("time"); return nil }
        tick.nodeCount += 1

        let n = Node()
        var childEls: [AXUIElement] = []

        var namesRef: CFArray?
        var names: [String] = []
        if AXUIElementCopyAttributeNames(el, &namesRef) == .success, let a = namesRef as? [String] { names = a }

        var out: CFArray?
        if !names.isEmpty,
           AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
           let vals = out {
            var pos: String?, size: String?
            for (i, name) in names.enumerated() where i < CFArrayGetCount(vals) {
                guard let rawp = CFArrayGetValueAtIndex(vals, i) else { continue }
                let v = Unmanaged<CFTypeRef>.fromOpaque(rawp).takeUnretainedValue()
                if name == "AXChildren" {
                    if CFGetTypeID(v) == CFArrayGetTypeID() {
                        let arr = v as! CFArray
                        for k in 0..<CFArrayGetCount(arr) {
                            if let cp = CFArrayGetValueAtIndex(arr, k) {
                                childEls.append(Unmanaged<AXUIElement>.fromOpaque(cp).takeUnretainedValue())
                            }
                        }
                    }
                    continue
                }
                if structural.contains(name) { continue }
                guard let s = simplify(v) else { continue }
                if name == "AXPosition" { pos = s; continue }
                if name == "AXSize" { size = s; continue }
                if framePieces.contains(name) { continue }
                let key = standardMap[name] ?? name
                let val = truncated(s)
                n.raw[key] = val
                n.attrs[key] = shown(key, val)
            }
            if let p = pos, let s = size { n.attrs["frame"] = "\(p),\(s)" }
        }
        let nonstd = names.filter { standardMap[$0] == nil && !framePieces.contains($0) && !structural.contains($0) && $0 != "AXChildren" }
        n.attrs["_attrNames"] = names.joined(separator: ",")
        _ = nonstd

        let role = n.raw["role"] ?? "?"
        n.path = parentPath + "/" + role + "[\(index)]"
        var idKey = "\(pid):\(CFHash(el))"
        if tick.flat[idKey] != nil { idKey += "#\(tick.nodeCount)" }
        n.id = idKey

        // Context for summary heuristics.
        var c = ctx
        let ident = [n.raw["role"], n.raw["description"], n.raw["roleDescription"], n.raw["title"], n.raw["identifier"],
                     n.raw["AXDOMClassList"], n.raw["AXDOMIdentifier"]].compactMap { $0 }.joined(separator: " ")
        if ["AXList", "AXTable", "AXOutline"].contains(role) { c.inList = true }
        if containsAny(ident, captionWords) { c.caption = true; note(&col.captionHits, "[caption node] \(role) \(redactIfNeeded(n.raw["description"] ?? n.raw["title"] ?? n.raw["roleDescription"] ?? ""))") }
        if containsAny([n.raw["description"], n.raw["title"], n.raw["roleDescription"]].compactMap { $0 }.joined(separator: " "), participantWords) { c.participant = true }
        classify(n, role: role, ctx: ctx, own: c)

        tick.flat[n.id] = n
        if depth >= maxDepth {
            if !childEls.isEmpty { tick.capped.insert("depth") }
        } else {
            for (i, ch) in childEls.enumerated() {
                if let cn = walk(ch, parentPath: n.path, index: i, depth: depth + 1, ctx: c, pid: pid) { n.children.append(cn) }
                else if tick.capped.contains("nodes") || tick.capped.contains("time") { break }
            }
        }
        return n
    }

    func note(_ d: inout [String: Int], _ k: String) { d[k, default: 0] += 1 }
    func redactIfNeeded(_ s: String) -> String { opts.redact ? redact(s) : truncated(s, 60) }

    func classify(_ n: Node, role: String, ctx: Ctx, own: Ctx) {
        let textKeys = ["title", "description", "value", "help"]
        // name-like labels
        let label = textKeys.compactMap { n.raw[$0] }.first { !$0.isEmpty }
        if let l = label {
            if role == "AXStaticText", looksLikeName(l) {
                note(&col.labelCands, "tile/name label | \(role) | \(redactIfNeeded(l))")
            }
            if own.participant || ctx.inList, ["AXRow", "AXCell", "AXStaticText", "AXGroup"].contains(role), looksLikeName(l) {
                note(&col.labelCands, "participant row | \(role) | \(redactIfNeeded(l))")
            }
            if own.caption, role == "AXStaticText" || n.raw["value"] != nil {
                note(&col.captionHits, "[text under captions] \(role) \(redactIfNeeded(l))")
            }
        }
        // status / speaking-ish words in any text attribute (including non-standard ones)
        for (k, v) in n.raw where k != "role" && k != "subrole" && k != "_attrNames" {
            let tags = statusTags(v)
            if !tags.isEmpty {
                note(&col.statusHits, "\(role).\(k) [\(tags.joined(separator: ","))] e.g. \(redactIfNeeded(v))")
            }
        }
    }
}

// MARK: - Enable flags

let chromiumPrefixes = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
                        "org.chromium.Chromium", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

func candidates(_ t: String) -> [String] {
    switch t.lowercased() {
    case "zoom": return ["us.zoom.xos"]
    case "teams": return ["com.microsoft.teams2", "com.microsoft.teams"]
    case "chrome": return ["com.google.Chrome"]
    case "safari": return ["com.apple.Safari"]
    default: return [t]
    }
}

var restoreList: [(AXUIElement, String, pid_t)] = []

func setFlag(_ el: AXUIElement, _ name: String, _ pid: pid_t) -> AXError {
    let prev = axCopy(el, name)
    var wasTrue = false
    if prev.0 == .success, let v = prev.1, CFGetTypeID(v) == CFBooleanGetTypeID() { wasTrue = CFBooleanGetValue((v as! CFBoolean)) }
    let e = AXUIElementSetAttributeValue(el, name as CFString, kCFBooleanTrue)
    if e == .success && !wasTrue { restoreList.append((el, name, pid)) }
    return e
}

func restoreFlags() {
    for (el, name, _) in restoreList { _ = AXUIElementSetAttributeValue(el, name as CFString, kCFBooleanFalse) }
    restoreList.removeAll()
}

func rootsFor(_ app: AXUIElement) -> [AXUIElement] {
    var r: [AXUIElement] = []
    let (e, v) = axCopy(app, "AXWindows")
    if e == .success, let arr = v as? [AXUIElement] { r = arr }
    if r.isEmpty, case let (e2, v2) = axCopy(app, "AXChildren"), e2 == .success, let arr = v2 as? [AXUIElement] { r = arr }
    return r
}

func quickCount(_ app: AXUIElement, pid: pid_t, limit: Int = 3000) -> (Int, Int) {
    let w = Walker(maxNodes: limit, maxDepth: opts.maxDepth, deadline: Date().addingTimeInterval(0.8))
    let roots = rootsFor(app)
    for (i, r) in roots.enumerated() { _ = w.walk(r, parentPath: "", index: i, depth: 0, ctx: Ctx(), pid: pid) }
    return (w.tick.nodeCount, roots.count)
}

// MARK: - Locate the app

let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

var found: NSRunningApplication?
var bundleId = ""
for cand in candidates(opts.target) {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: cand).filter { !$0.isTerminated }
    if let a = apps.first(where: { $0.activationPolicy == .regular }) ?? apps.first { found = a; bundleId = cand; break }
}
guard let app = found, let bundleURL = app.bundleURL else {
    fail("ax-probe: no running app found for '\(opts.target)' (tried: \(candidates(opts.target).joined(separator: ", "))). Start the app first.", code: 3)
}
let bundlePath = bundleURL.path
let mainPid = app.processIdentifier
let isChromium = chromiumPrefixes.contains { bundleId.hasPrefix($0) }
let isTeams = bundleId.hasPrefix("com.microsoft.teams")
let known = isChromium || isTeams || bundleId == "us.zoom.xos" || bundleId == "com.apple.Safari"
let shouldEnable = !opts.noEnable && (isChromium || isTeams || !known)

// MARK: - Output dir

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path
let stamp: String = {
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
}()
let outDir = URL(fileURLWithPath: opts.out ?? "/tmp/ax-probe-\(opts.target.replacingOccurrences(of: "/", with: "_"))-\(stamp)").standardizedFileURL
let outParent = outDir.deletingLastPathComponent().resolvingSymlinksInPath().path
if outParent == repoRoot || outParent.hasPrefix(repoRoot + "/") {
    fail("ax-probe: refusing to write output inside the repo (\(repoRoot)). Pick a dir under /tmp.", code: 4)
}
do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
} catch { fail("ax-probe: cannot create \(outDir.path): \(error)", code: 4) }

var summaryLines: [String] = []
func say(_ s: String) { print(s); summaryLines.append(s) }

print("ax-probe: \(bundleId) pid \(mainPid) -> \(outDir.path)\(opts.redact ? "  (redacted)" : "  (CONTAINS REAL NAMES: do not commit or paste)")")

// Stop handling
var stopRequested = false
var sigSources: [DispatchSourceSignal] = []
for s in [SIGINT, SIGTERM] {
    signal(s, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: s, queue: DispatchQueue.global())
    src.setEventHandler { stopRequested = true }
    src.resume(); sigSources.append(src)
}

// MARK: - Enable web tree

let appEl = AXUIElementCreateApplication(mainPid)
AXUIElementSetMessagingTimeout(appEl, 0.5)
var targetPids: [(pid: pid_t, name: String, el: AXUIElement)] = [(mainPid, "main", appEl)]
var enableReport: [String] = []
var cpuBefore = "n/a", cpuAfter = "n/a"
let procs = pids(inBundle: bundlePath)

if shouldEnable {
    let (n0, w0) = quickCount(appEl, pid: mainPid)
    let base0 = cpuSnapshot(procs)
    Thread.sleep(forTimeInterval: 1.5)
    let base1 = cpuSnapshot(procs)
    cpuBefore = String(format: "%.1f%% of one core (%d processes, 1.5 s)", cpuPercent(base0, base1, over: 1.5), procs.count)
    enableReport.append("before enabling: \(n0) nodes in \(w0) top-level elements")

    var took = "neither"
    for flag in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
        let e = setFlag(appEl, flag, mainPid)
        Thread.sleep(forTimeInterval: 0.5)
        let (n1, _) = quickCount(appEl, pid: mainPid)
        enableReport.append("\(flag): set result \(e.rawValue) (\(e == .success ? "success" : "failed")), nodes after 500 ms: \(n1)")
        if e == .success && n1 > n0 { took = flag; break }
        if e == .success && took == "neither" { took = flag + " (accepted, but node count did not grow)" }
        if e == .success && n1 > 0 && n0 == 0 { took = flag; break }
    }
    enableReport.append("took: \(took)")
    let a0 = cpuSnapshot(pids(inBundle: bundlePath))
    Thread.sleep(forTimeInterval: 1.5)
    let a1 = cpuSnapshot(pids(inBundle: bundlePath))
    cpuAfter = String(format: "%.1f%% of one core (%d processes, 1.5 s)", cpuPercent(a0, a1, over: 1.5), pids(inBundle: bundlePath).count)
} else {
    enableReport.append(opts.noEnable ? "enable flags skipped (--no-enable)" : "enable flags not needed for this app")
}

// Helper processes (Teams / unknown bundles) when the main tree is empty.
if isTeams || !known {
    let (n, _) = quickCount(appEl, pid: mainPid)
    if n < 15 {
        enableReport.append("main process tree is near-empty (\(n) nodes); trying helper processes")
        for p in procs where p != mainPid {
            let el = AXUIElementCreateApplication(p)
            AXUIElementSetMessagingTimeout(el, 0.5)
            if shouldEnable { _ = setFlag(el, "AXManualAccessibility", p); Thread.sleep(forTimeInterval: 0.2) }
            let (hn, hw) = quickCount(el, pid: p)
            let nm = (pidPath(p) ?? "?").split(separator: "/").last.map(String.init) ?? "?"
            enableReport.append("  helper pid \(p) \(nm): \(hn) nodes, \(hw) top-level elements")
            if hn >= 15 { targetPids.append((p, nm, el)) }
        }
        enableReport.append(targetPids.count > 1 ? "helpers with content are included in the walk" : "no helper process exposed a tree")
    }
}

// MARK: - Main loop

func writeJSON(_ obj: Any, to name: String, pretty: Bool) {
    let d = try? JSONSerialization.data(withJSONObject: obj, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
    if let d = d { try? d.write(to: outDir.appendingPathComponent(name)) }
}

let logURL = outDir.appendingPathComponent("changes.jsonl")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try? FileHandle(forWritingTo: logURL)
func logLine(_ o: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
        logHandle?.write(d); logHandle?.write("\n".data(using: .utf8)!)
    }
}

func walkAll(budget: TimeInterval) -> Tick {
    let start = Date()
    let w = Walker(maxNodes: opts.maxNodes, maxDepth: opts.maxDepth, deadline: start.addingTimeInterval(budget))
    var idx = 0
    for t in targetPids {
        for r in rootsFor(t.el) {
            if let n = w.walk(r, parentPath: t.pid == mainPid ? "" : "helper\(t.pid)", index: idx, depth: 0, ctx: Ctx(), pid: t.pid) { w.tick.roots.append(n) }
            idx += 1
        }
    }
    w.tick.seconds = Date().timeIntervalSince(start)
    return w.tick
}

let runStart = Date()
let cpuRunStart = cpuSnapshot(pids(inBundle: bundlePath))
let selfStart = selfCPU()
var prev: Tick?
var last: Tick?
var tickNo = 0

while !stopRequested {
    let t0 = Date()
    let cur = walkAll(budget: opts.interval * 0.8)
    let ts = iso.string(from: t0)
    col.ticks += 1
    col.maxNodesSeen = max(col.maxNodesSeen, cur.nodeCount)
    if !cur.capped.isEmpty { col.cappedTicks += 1 }
    var changeCount = 0

    if let p = prev {
        let bothComplete = cur.capped.isEmpty && p.capped.isEmpty
        for (id, node) in cur.flat {
            guard let old = p.flat[id] else { continue }
            var diffs: [String: [String]] = [:]
            for k in Set(node.attrs.keys).union(old.attrs.keys) {
                let a = old.attrs[k] ?? "<none>", b = node.attrs[k] ?? "<none>"
                if a != b { diffs[k] = [a, b] }
            }
            if diffs.isEmpty { continue }
            changeCount += 1
            col.changedNodes.insert(id)
            let role = node.raw["role"] ?? "?"
            for (k, ab) in diffs {
                col.totalChangeEvents += 1
                col.attrChangeCounts["\(role).\(k)", default: 0] += 1
                let fk = id + "|" + k
                var st = col.flipStats[fk] ?? (0, [], role, k)
                st.changes += 1; st.values.insert(ab[0]); st.values.insert(ab[1])
                col.flipStats[fk] = st
            }
            logLine(["ts": ts, "tick": tickNo, "event": "changed", "id": id, "path": node.path, "role": role, "changes": diffs])
        }
        if bothComplete {
            var emitted = 0
            for (id, node) in cur.flat where p.flat[id] == nil {
                if emitted >= 200 { break }
                emitted += 1
                logLine(["ts": ts, "tick": tickNo, "event": "added", "id": id, "path": node.path, "attrs": node.attrs])
            }
            for (id, node) in p.flat where cur.flat[id] == nil {
                if emitted >= 400 { break }
                emitted += 1
                logLine(["ts": ts, "tick": tickNo, "event": "removed", "id": id, "path": node.path, "role": node.raw["role"] ?? "?"])
            }
        }
    } else {
        writeJSON(["meta": ["bundleId": bundleId, "pid": Int(mainPid), "time": ts, "redacted": opts.redact,
                             "capped": Array(cur.capped), "nodes": cur.nodeCount],
                   "tree": cur.roots.map { $0.json }], to: "snapshot-start.json", pretty: true)
    }

    print(String(format: "tick %3d  nodes %5d  changed %3d  walk %.2fs%@", tickNo, cur.nodeCount, changeCount, cur.seconds,
                 cur.capped.isEmpty ? "" : "  CAPPED(\(cur.capped.sorted().joined(separator: ",")))"))
    prev = cur; last = cur; tickNo += 1

    if Date().timeIntervalSince(runStart) >= opts.seconds { break }
    let wake = t0.addingTimeInterval(opts.interval)
    while Date() < wake && !stopRequested { Thread.sleep(forTimeInterval: 0.05) }
}

let runSecs = Date().timeIntervalSince(runStart)
let cpuRunEnd = cpuSnapshot(pids(inBundle: bundlePath))
let selfUsed = selfCPU() - selfStart

if let l = last {
    writeJSON(["meta": ["bundleId": bundleId, "pid": Int(mainPid), "time": iso.string(from: Date()), "redacted": opts.redact,
                         "capped": Array(l.capped), "nodes": l.nodeCount],
               "tree": l.roots.map { $0.json }], to: "snapshot-end.json", pretty: true)
}
try? logHandle?.close()
restoreFlags()

// MARK: - Summary

func top<K>(_ d: [K: Int], _ n: Int) -> [(K, Int)] where K: Hashable {
    Array(d.sorted { $0.value > $1.value }.prefix(n))
}

say("")
say("=== ax-probe summary: \(bundleId) ===")
say("ticks: \(col.ticks) over \(String(format: "%.1f", runSecs)) s; nodes per walk: last \(last?.nodeCount ?? 0), max \(col.maxNodesSeen)")
say("capped walks: \(col.cappedTicks)/\(col.ticks)\(col.cappedTicks > 0 ? "  (raise --max-nodes/--max-depth or --interval; diffs on capped ticks are partial)" : "")")
say("enable: " + enableReport.joined(separator: "\n        "))
say("target CPU before enabling: \(cpuBefore)")
say("target CPU after enabling:  \(cpuAfter)")
say(String(format: "target CPU over whole run (with probe walking): %.1f%% of one core", cpuPercent(cpuRunStart, cpuRunEnd, over: runSecs)))
say(String(format: "probe CPU time: %.2f s (%.1f%% of one core)", selfUsed, runSecs > 0 ? selfUsed / runSecs * 100 : 0))
say("change events: \(col.totalChangeEvents) across \(col.changedNodes.count) nodes")

say("\nName-like labels / participant rows (top 12):")
for (k, c) in top(col.labelCands, 12) { say("  \(c)x  \(k)") }
if col.labelCands.isEmpty { say("  none found") }

say("\nAttributes that changed most often (top 10, role.attribute):")
for (k, c) in top(col.attrChangeCounts, 10) { say("  \(c)x  \(k)") }
if col.attrChangeCounts.isEmpty { say("  no changes seen") }

say("\nFlip candidates: one node, one attribute, 2-4 distinct values, 2+ changes (top 10):")
let flips = col.flipStats.values.filter { $0.changes >= 2 && $0.values.count >= 2 && $0.values.count <= 4 && $0.attr != "frame" }
    .sorted { $0.changes > $1.changes }.prefix(10)
for f in flips { say("  \(f.changes)x  \(f.role).\(f.attr)  values: \(f.values.sorted().map { truncated($0, 40) }.joined(separator: " | "))") }
if flips.isEmpty { say("  none") }

say("\nStatus / speaking words in any attribute (top 10):")
for (k, c) in top(col.statusHits, 10) { say("  \(c)x  \(k)") }
if col.statusHits.isEmpty { say("  none") }

say("\nCaptions (nodes mentioning caption/subtitle/transcript, and text beneath them; top 8):")
for (k, c) in top(col.captionHits, 8) { say("  \(c)x  \(k)") }
if col.captionHits.isEmpty { say("  none") }

say("\noutput: \(outDir.path)")
say(opts.redact ? "Redacted: text values are hashes (stable within this run only)." : "This output contains real names. Keep it in /tmp. Do not commit or paste it.")
try? summaryLines.joined(separator: "\n").write(to: outDir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
exit(0)
