// ax-probe.swift - dev-only, read-only Accessibility (AXUIElement) probe.
// NOT part of the MeetMouse app target. See scripts/ax-probe.md.
//
//   swift scripts/ax-probe.swift <zoom|teams|teams-classic|chrome|safari|bundle-id>
//        [--seconds 60] [--interval 1] [--out DIR] [--redact]
//        [--max-nodes 4000] [--max-depth 50] [--no-enable] [--window TEXT]
//
// Passive: it only reads attributes. The single exception is the two
// accessibility-enable flags (AXManualAccessibility, AXEnhancedUserInterface)
// set on the application element of Chromium browsers, Teams and other
// Electron/WebView2 apps, restored on exit (including Ctrl-C, SIGTERM, SIGHUP).
// No actions, clicks, focus or raise. No network.

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
    var window: String?
}

func fail(_ msg: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func usage() -> Never {
    fail("""
    usage: swift scripts/ax-probe.swift <zoom|teams|teams-classic|chrome|safari|bundle-id> [options]
      --seconds N      total run time (default 60)
      --interval N     seconds between tree walks (default 1, min 0.2)
      --out DIR        new output directory (default: new dir under /tmp; refuses any git repo)
      --redact         replace text values with a short hash plus length
      --max-nodes N    node cap per walk (default 4000)
      --max-depth N    depth cap per walk (default 50)
      --no-enable      do not set the accessibility-enable flags
      --window TEXT    only walk windows whose title contains TEXT (case-insensitive)
    """)
}

func parseOptions(_ args: [String]) -> Options {
    var o = Options()
    var it = args.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("ax-probe: \(flag) needs a value") }
        return v
    }
    func number(_ flag: String) -> Double {
        let s = value(flag)
        guard let d = Double(s), d.isFinite else { fail("ax-probe: \(flag) expects a number, got '\(s)'") }
        return d
    }
    func count(_ flag: String) -> Int {
        let s = value(flag)
        guard let n = Int(s), n > 0 else { fail("ax-probe: \(flag) expects a positive integer, got '\(s)'") }
        return n
    }
    while let a = it.next() {
        switch a {
        case "--seconds": o.seconds = number(a)
        case "--interval": o.interval = number(a)
        case "--out": o.out = value(a)
        case "--redact": o.redact = true
        case "--max-nodes": o.maxNodes = count(a)
        case "--max-depth": o.maxDepth = count(a)
        case "--no-enable": o.noEnable = true
        case "--window": o.window = value(a).lowercased()
        case "-h", "--help": usage()
        default:
            if a.hasPrefix("-") { fail("ax-probe: unknown option \(a)") }
            if !o.target.isEmpty { fail("ax-probe: more than one target ('\(o.target)', '\(a)')") }
            o.target = a
        }
    }
    if o.target.isEmpty { usage() }
    if o.seconds <= 0 { fail("ax-probe: --seconds must be > 0") }
    if o.interval < 0.2 { fail("ax-probe: --interval must be >= 0.2") }
    return o
}

// CommandLine.arguments[0] is the script (or binary) path.
let opts = parseOptions(Array(CommandLine.arguments.dropFirst()))

// MARK: - Step 1: trust check (never prompts)

// AXIsProcessTrusted() never shows the system prompt (only the WithOptions
// variant with kAXTrustedCheckOptionPrompt does).
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

// Global AX messaging timeout for every element this process talks to, so an
// unresponsive app cannot hang a walk for the 6 s default per call.
let axTimeout: Float = 0.5
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout)

// MARK: - Stop flag (signal-safe)

final class StopFlag {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
let stop = StopFlag()
var sigSources: [DispatchSourceSignal] = []
// A closed pipe (`| head`, or Ctrl-C killing `tee`) must not kill the probe
// before the accessibility flags are restored and the end snapshot is written.
signal(SIGPIPE, SIG_IGN)
for s in [SIGINT, SIGTERM, SIGHUP] {
    signal(s, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: s, queue: DispatchQueue.global())
    src.setEventHandler { stop.set() }
    src.resume(); sigSources.append(src)
}

// MARK: - Redaction

let salt = UInt64.random(in: 1...UInt64.max)
let statusVocab = ["unmuted", "muted", "speaking", "talking", "presenting", "presenter", "co-host", "host",
                   "pinned", "spotlight", "raised hand", "hand raised", "camera on", "camera off",
                   "video on", "video off", "active speaker", "screen sharing", "sharing", "captions"]

func statusTags(_ s: String) -> [String] {
    var l = s.lowercased()
    var tags: [String] = []
    if l.contains("unmuted") { tags.append("unmuted"); l = l.replacingOccurrences(of: "unmuted", with: "") }
    if l.contains("co-host") { tags.append("co-host"); l = l.replacingOccurrences(of: "co-host", with: "") }
    for w in statusVocab where w != "unmuted" && w != "co-host" && l.contains(w) { tags.append(w) }
    return tags
}

func redact(_ s: String) -> String {
    if s.isEmpty { return s }
    var h: UInt64 = 0xcbf29ce484222325 ^ salt
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    let tags = statusTags(s)
    return "h:" + String(h & 0xffffff, radix: 16) + "#\(s.count)" + (tags.isEmpty ? "" : "[" + tags.joined(separator: ",") + "]")
}

/// A simplified attribute value. Only `.text` values carry user content and get redacted;
/// numbers, booleans and geometry are typed values from the AX API, never strings.
enum AXV { case text(String), scalar(String) }

/// Structural keys whose text is developer-set, not user content, kept under --redact.
let keepUnredacted: Set<String> = ["role", "subrole", "roleDescription", "identifier", "AXDOMClassList", "AXDOMIdentifier"]

func shown(_ key: String, _ v: AXV) -> String {
    switch v {
    case .scalar(let s): return s
    case .text(let s): return (!opts.redact || keepUnredacted.contains(key)) ? s : redact(s)
    }
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

/// proc_taskinfo times are mach absolute units on Apple Silicon; convert to seconds.
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

func truncated(_ s: String, _ n: Int = 200) -> String { s.count > n ? String(s.prefix(n)) + "..." : s }

func simplify(_ v: CFTypeRef, depth: Int = 0) -> AXV? {
    let t = CFGetTypeID(v)
    if t == CFStringGetTypeID() { return .text(truncated((v as! CFString) as String)) }
    if t == CFAttributedStringGetTypeID() { return .text(truncated(CFAttributedStringGetString((v as! CFAttributedString)) as String)) }
    if t == CFBooleanGetTypeID() { return .scalar(CFBooleanGetValue((v as! CFBoolean)) ? "true" : "false") }
    if t == CFNumberGetTypeID() { return .scalar((v as! NSNumber).stringValue) }
    if t == CFURLGetTypeID() { return .text(truncated((v as! CFURL as URL).absoluteString)) }
    if t == AXValueGetTypeID() {
        let av = v as! AXValue
        // Apps do report NaN/inf geometry; Int(_:) would trap and skip the flag restore.
        func i(_ d: CGFloat) -> String { d.isFinite && abs(d) < 1e9 ? String(Int(d)) : "nan" }
        switch AXValueGetType(av) {
        case .cgPoint: var p = CGPoint.zero; AXValueGetValue(av, .cgPoint, &p); return .scalar("\(i(p.x)),\(i(p.y))")
        case .cgSize: var s = CGSize.zero; AXValueGetValue(av, .cgSize, &s); return .scalar("\(i(s.width)),\(i(s.height))")
        case .cgRect: var r = CGRect.zero; AXValueGetValue(av, .cgRect, &r); return .scalar("\(i(r.origin.x)),\(i(r.origin.y)),\(i(r.size.width)),\(i(r.size.height))")
        case .cfRange: var r = CFRange(); AXValueGetValue(av, .cfRange, &r); return .scalar("\(r.location)+\(r.length)")
        default: return nil
        }
    }
    // Arrays of simple values (e.g. AXDOMClassList). Any text element makes the whole value text.
    if t == CFArrayGetTypeID(), depth == 0 {
        let arr = v as! [AnyObject]
        var parts: [String] = [], anyText = false
        for el in arr.prefix(20) {
            guard let s = simplify(el, depth: 1) else { return nil }   // element-valued arrays are skipped
            switch s { case .text(let x): anyText = true; parts.append(x); case .scalar(let x): parts.append(x) }
        }
        let j = truncated(parts.joined(separator: " "))
        return anyText ? .text(j) : .scalar(j)
    }
    return nil
}

// Standard attributes mapped to short keys.
let standardMap: [String: String] = [
    "AXRole": "role", "AXSubrole": "subrole", "AXTitle": "title", "AXDescription": "description",
    "AXValue": "value", "AXIdentifier": "identifier", "AXRoleDescription": "roleDescription",
    "AXSelected": "selected", "AXFocused": "focused", "AXEnabled": "enabled", "AXHelp": "help",
]
// Never fetched: element-valued (would only be skipped), or expensive text-marker/range values.
let skipFetch: Set<String> = [
    "AXParent", "AXWindow", "AXTopLevelUIElement", "AXVisibleChildren", "AXSelectedChildren",
    "AXChildrenInNavigationOrder", "AXRows", "AXVisibleRows", "AXSelectedRows", "AXColumns", "AXVisibleColumns",
    "AXSelectedColumns", "AXSelectedCells", "AXVisibleCells", "AXLinkedUIElements", "AXTitleUIElement",
    "AXServesAsTitleForUIElements", "AXLabelUIElements", "AXHeader", "AXContents", "AXTabs", "AXFocusedUIElement",
    "AXMenuItemPrimaryUIElement", "AXOwns", "AXDetailsElements", "AXErrorMessageElements",
    "AXStartTextMarker", "AXEndTextMarker", "AXSelectedTextMarkerRange", "AXTextMarkerRange",
    "AXSelectedTextRanges", "AXVisibleCharacterRange", "AXSharedTextUIElements", "AXSharedCharacterRange",
    "AXDefaultButton", "AXCancelButton", "AXCloseButton", "AXMinimizeButton", "AXZoomButton",
    "AXFullScreenButton", "AXToolbarButton", "AXProxy", "AXGrowArea", "AXHorizontalScrollBar", "AXVerticalScrollBar",
]
let framePieces: Set<String> = ["AXPosition", "AXSize", "AXFrame"]

// MARK: - Tree model and node identity

/// AX element identity: CFEqual on the AXUIElement (same remote object), the
/// strongest key AX offers. CFHash is only the bucket, never the identity.
struct ElKey: Hashable {
    let el: AXUIElement
    func hash(into h: inout Hasher) { h.combine(CFHash(el)) }
    static func == (a: ElKey, b: ElKey) -> Bool { CFEqual(a.el, b.el) }
}

final class Node {
    let key: ElKey
    var id = ""                            // stable across ticks (see assignIds)
    var path = ""                          // role[index] path, informational only
    var sig = ""                           // structural signature, fallback identity
    var attrs: [String: String] = [:]      // display (possibly redacted) values
    var raw: [String: String] = [:]        // unredacted text, memory only, used for summary matching
    var children: [Node] = []
    init(_ el: AXUIElement) { key = ElKey(el: el) }
    var json: [String: Any] {
        var d: [String: Any] = ["id": id, "path": path, "attrs": attrs]
        if !children.isEmpty { d["children"] = children.map { $0.json } }
        return d
    }
}

struct Ctx { var inList = false; var caption = false; var participant = false }

struct Tick {
    var roots: [Node] = []
    var order: [Node] = []          // walk order
    var flat: [String: Node] = [:]  // id -> node, filled by assignIds
    var byKey: [ElKey: String] = [:]
    var capped: Set<String> = []
    var nodeCount = 0
    var seconds = 0.0
    var axErrors = 0
    var timeouts = 0
    var matchedElement = 0, matchedStructure = 0, fresh = 0
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
    var overrunTicks = 0
    var maxWalk = 0.0, sumWalk = 0.0
    var axErrors = 0, timeouts = 0
    var matchedElement = 0, matchedStructure = 0, fresh = 0
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
    let maxNodes: Int, maxDepth: Int, deadline: Date, collect: Bool
    var tick = Tick()
    /// Elements already visited in this walk. AX trees can loop (an app whose
    /// AXChildren include itself), which would burn the whole time budget.
    var visited = Set<ElKey>()
    var consecutiveTimeouts = 0
    init(maxNodes: Int, maxDepth: Int, deadline: Date, collect: Bool) {
        self.maxNodes = maxNodes; self.maxDepth = maxDepth; self.deadline = deadline; self.collect = collect
    }

    var mustStop: Bool { tick.capped.contains("nodes") || tick.capped.contains("time") || tick.capped.contains("unresponsive") || tick.capped.contains("stopped") }

    func track(_ e: AXError) {
        if e == .success || e == .noValue || e == .attributeUnsupported { consecutiveTimeouts = 0; return }
        tick.axErrors += 1
        if e == .cannotComplete {
            tick.timeouts += 1; consecutiveTimeouts += 1
            if consecutiveTimeouts >= 3 { tick.capped.insert("unresponsive") }
        }
    }

    func walk(_ el: AXUIElement, parentPath: String, index: Int, depth: Int, ctx: Ctx) -> Node? {
        if mustStop { return nil }
        if tick.nodeCount >= maxNodes { tick.capped.insert("nodes"); return nil }
        if Date() > deadline { tick.capped.insert("time"); return nil }
        if stop.isSet { tick.capped.insert("stopped"); return nil }
        if !visited.insert(ElKey(el: el)).inserted { return nil }
        tick.nodeCount += 1

        let n = Node(el)
        var childEls: [AXUIElement] = []

        var namesRef: CFArray?
        var names: [String] = []
        let ne = AXUIElementCopyAttributeNames(el, &namesRef)
        track(ne)
        if ne == .success, let a = namesRef as? [String] { names = a }
        let fetch = names.filter { !skipFetch.contains($0) }

        var out: CFArray?
        if !fetch.isEmpty {
            let me = AXUIElementCopyMultipleAttributeValues(el, fetch as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
            track(me)
            if me == .success, let vals = out as? [AnyObject] {
                var pos: String?, size: String?
                for (i, name) in fetch.enumerated() where i < vals.count {
                    let v = vals[i]
                    if name == "AXChildren" {
                        if CFGetTypeID(v) == CFArrayGetTypeID(), let arr = v as? [AnyObject] {
                            for c in arr where CFGetTypeID(c) == AXUIElementGetTypeID() { childEls.append(c as! AXUIElement) }
                        }
                        continue
                    }
                    guard let s = simplify(v) else { continue }
                    if name == "AXPosition", case .scalar(let x) = s { pos = x; continue }
                    if name == "AXSize", case .scalar(let x) = s { size = x; continue }
                    if framePieces.contains(name) { continue }
                    let key = standardMap[name] ?? name
                    if case .text(let x) = s { n.raw[key] = x } else if case .scalar(let x) = s { n.raw[key] = x }
                    n.attrs[key] = shown(key, s)
                }
                if let p = pos, let s = size { n.attrs["frame"] = "\(p),\(s)" }
            }
        }
        let nonstd = names.filter { standardMap[$0] == nil && !framePieces.contains($0) && !skipFetch.contains($0) && $0 != "AXChildren" }
        if !nonstd.isEmpty { n.attrs["_nonStdAttrs"] = nonstd.sorted().joined(separator: ",") }

        let role = n.raw["role"] ?? "?"
        n.path = parentPath + "/" + role + "[\(index)]"
        tick.order.append(n)

        // Context for summary heuristics.
        var c = ctx
        if collect {
            let ident = [n.raw["role"], n.raw["description"], n.raw["roleDescription"], n.raw["title"], n.raw["identifier"],
                         n.raw["AXDOMClassList"], n.raw["AXDOMIdentifier"]].compactMap { $0 }.joined(separator: " ")
            if ["AXList", "AXTable", "AXOutline"].contains(role) { c.inList = true }
            if containsAny(ident, captionWords) {
                c.caption = true
                note(&col.captionHits, "[caption node] \(role) \(redactIfNeeded(n.raw["description"] ?? n.raw["title"] ?? n.raw["roleDescription"] ?? ""))")
            }
            if containsAny([n.raw["description"], n.raw["title"], n.raw["roleDescription"]].compactMap { $0 }.joined(separator: " "), participantWords) { c.participant = true }
            classify(n, role: role, ctx: ctx, own: c)
        }

        if depth >= maxDepth {
            if !childEls.isEmpty { tick.capped.insert("depth") }
        } else {
            for (i, ch) in childEls.enumerated() {
                if mustStop { break }
                if let cn = walk(ch, parentPath: n.path, index: i, depth: depth + 1, ctx: c) { n.children.append(cn) }
            }
        }
        return n
    }

    /// Structural signature: role, subrole and identifier down the tree, with an index that only
    /// counts siblings of the same kind, so inserting a different kind of sibling does not shift it.
    static func assignSigs(_ nodes: [Node], parentSig: String) {
        var seen: [String: Int] = [:]
        for n in nodes {
            let k = (n.raw["role"] ?? "?") + ":" + (n.raw["subrole"] ?? "") + "#" + (n.raw["identifier"] ?? n.raw["AXDOMIdentifier"] ?? "")
            let i = seen[k, default: 0]; seen[k] = i + 1
            n.sig = parentSig + "/" + k + "[\(i)]"
            assignSigs(n.children, parentSig: n.sig)
        }
    }

    func note(_ d: inout [String: Int], _ k: String) { d[k, default: 0] += 1 }
    func redactIfNeeded(_ s: String) -> String { opts.redact ? redact(s) : truncated(s, 60) }

    func classify(_ n: Node, role: String, ctx: Ctx, own: Ctx) {
        let textKeys = ["title", "description", "value", "help"]
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
        for (k, v) in n.raw where !["role", "subrole", "identifier", "AXDOMClassList"].contains(k) {
            let tags = statusTags(v)
            if !tags.isEmpty {
                note(&col.statusHits, "\(role).\(k) [\(tags.joined(separator: ","))] e.g. \(redactIfNeeded(v))")
            }
        }
    }
}

/// Give each node of `cur` a run-stable id. First by AX element identity against the
/// previous tick; then, for nodes whose element was re-created, by structural signature
/// when that signature is unique in both ticks; otherwise a fresh id.
var nextId = 0
func assignIds(_ cur: inout Tick, prev: Tick?) {
    var used = Set<String>()
    var unmatched: [Node] = []
    for n in cur.order {
        if let p = prev, let id = p.byKey[n.key], !used.contains(id) {
            n.id = id; used.insert(id); cur.matchedElement += 1
        } else { unmatched.append(n) }
    }
    if let p = prev, !unmatched.isEmpty {
        var prevSig: [String: [Node]] = [:]
        for n in p.order where !used.contains(n.id) { prevSig[n.sig, default: []].append(n) }
        var curSig: [String: Int] = [:]
        for n in unmatched { curSig[n.sig, default: 0] += 1 }
        var rest: [Node] = []
        for n in unmatched {
            if curSig[n.sig] == 1, let cands = prevSig[n.sig], cands.count == 1, !used.contains(cands[0].id) {
                n.id = cands[0].id; used.insert(n.id); cur.matchedStructure += 1
            } else { rest.append(n) }
        }
        unmatched = rest
    }
    for n in unmatched { nextId += 1; n.id = "n\(nextId)"; used.insert(n.id); cur.fresh += 1 }
    for n in cur.order {
        cur.flat[n.id] = n
        if cur.byKey[n.key] == nil { cur.byKey[n.key] = n.id }
    }
}

// MARK: - Locate the app

func candidates(_ t: String) -> [String] {
    switch t.lowercased() {
    case "zoom": return ["us.zoom.xos"]
    case "teams": return ["com.microsoft.teams2", "com.microsoft.teams"]
    case "teams-classic": return ["com.microsoft.teams"]
    case "chrome": return ["com.google.Chrome"]
    case "safari": return ["com.apple.Safari"]
    default: return [t]
    }
}

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

let chromiumPrefixes = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
                        "org.chromium.Chromium", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
let webShellFrameworks = ["Electron Framework.framework", "MSWebView2.framework", "Chromium Embedded Framework.framework"]
let isChromium = chromiumPrefixes.contains { bundleId.hasPrefix($0) }
let isTeams = bundleId.hasPrefix("com.microsoft.teams")
let isWebShell = webShellFrameworks.contains { FileManager.default.fileExists(atPath: bundlePath + "/Contents/Frameworks/" + $0) }
// Flags only go to apps that need them for a web tree; Zoom, Safari and native apps are never touched.
let shouldEnable = !opts.noEnable && (isChromium || isTeams || isWebShell)

// MARK: - Output dir (never inside a git checkout)

let defaultName = "ax-probe-\(opts.target.replacingOccurrences(of: "/", with: "_"))-" + {
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
}()
let outDir = URL(fileURLWithPath: opts.out ?? "/tmp/\(defaultName)").absoluteURL.standardizedFileURL.resolvingSymlinksInPath()
do {
    var u = outDir
    while u.path != "/" {
        if FileManager.default.fileExists(atPath: u.appendingPathComponent(".git").path) {
            fail("ax-probe: refusing to write output inside a git checkout (\(u.path)). Use a dir under /tmp.", code: 4)
        }
        u = u.deletingLastPathComponent()
    }
    if let existing = try? FileManager.default.contentsOfDirectory(atPath: outDir.path), !existing.isEmpty {
        fail("ax-probe: \(outDir.path) already exists and is not empty. Pick a new dir.", code: 4)
    }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
} catch { fail("ax-probe: cannot create \(outDir.path): \(error)", code: 4) }

var summaryLines: [String] = []
func say(_ s: String) { print(s); summaryLines.append(s) }

print("ax-probe: \(bundleId) pid \(mainPid) -> \(outDir.path)\(opts.redact ? "  (redacted)" : "  (CONTAINS REAL NAMES: do not commit or paste)")")
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Enable web tree (the only writes this script makes)

enum Prior { case wasFalse, unknown }
var restoreList: [(el: AXUIElement, name: String, pid: pid_t, prior: Prior)] = []

/// Sets one flag to true. Remembers it for restore unless it was already readably true
/// (another assistive app or the user turned it on; leave it as found).
func setFlag(_ el: AXUIElement, _ name: String, _ pid: pid_t) -> AXError {
    let (pe, pv) = axCopy(el, name)
    var prior = Prior.unknown
    if pe == .success, let v = pv, CFGetTypeID(v) == CFBooleanGetTypeID() {
        if CFBooleanGetValue((v as! CFBoolean)) { return .success }
        prior = .wasFalse
    }
    let e = AXUIElementSetAttributeValue(el, name as CFString, kCFBooleanTrue)
    if e == .success { restoreList.append((el, name, pid, prior)) }
    return e
}

func restoreFlags() {
    for r in restoreList.reversed() {
        let e = AXUIElementSetAttributeValue(r.el, r.name as CFString, kCFBooleanFalse)
        print("restore \(r.name) on pid \(r.pid): \(e == .success ? "ok" : "failed (\(e.rawValue))")\(r.prior == .unknown ? " (prior value was unreadable; reset to false)" : "")")
    }
    restoreList.removeAll()
}

func rootsFor(_ app: AXUIElement) -> [AXUIElement] {
    let (e, v) = axCopy(app, "AXWindows")
    if e == .success, let arr = v as? [AXUIElement], !arr.isEmpty {
        guard let want = opts.window else { return arr }
        return arr.filter { (axCopy($0, "AXTitle").1 as? String)?.lowercased().contains(want) == true }
    }
    if opts.window != nil { return [] }
    let (e2, v2) = axCopy(app, "AXChildren")
    if e2 == .success, let arr = v2 as? [AXUIElement] { return arr }
    return []
}

func quickCount(_ app: AXUIElement, limit: Int = 3000) -> (Int, Int) {
    let w = Walker(maxNodes: limit, maxDepth: opts.maxDepth, deadline: Date().addingTimeInterval(1.0), collect: false)
    let roots = rootsFor(app)
    for (i, r) in roots.enumerated() { _ = w.walk(r, parentPath: "", index: i, depth: 0, ctx: Ctx()) }
    return (w.tick.nodeCount, roots.count)
}

let appEl = AXUIElementCreateApplication(mainPid)
var targets: [(pid: pid_t, name: String, el: AXUIElement)] = [(mainPid, "main", appEl)]
var enableReport: [String] = []
var cpuBefore = "n/a (flags not set)", cpuAfter = "n/a (flags not set)"

if shouldEnable {
    let procs0 = pids(inBundle: bundlePath)
    let (n0, w0) = quickCount(appEl)
    let b0 = cpuSnapshot(procs0)
    Thread.sleep(forTimeInterval: 1.5)
    let b1 = cpuSnapshot(procs0)
    cpuBefore = String(format: "%.1f%% of one core (%d processes, 1.5 s)", cpuPercent(b0, b1, over: 1.5), procs0.count)
    enableReport.append("before enabling: \(n0) nodes in \(w0) top-level elements")

    var took = "neither"
    for flag in ["AXManualAccessibility", "AXEnhancedUserInterface"] where !stop.isSet {
        let e = setFlag(appEl, flag, mainPid)
        Thread.sleep(forTimeInterval: 0.5)
        let (n1, _) = quickCount(appEl)
        enableReport.append("\(flag): set \(e == .success ? "accepted" : "rejected (\(e.rawValue))"), nodes after 500 ms: \(n1)")
        if e == .success && n1 >= n0 + 10 { took = flag; break }   // web tree appeared: no fallback needed
        if e == .success && took == "neither" { took = flag + " (accepted, tree did not grow)" }
    }
    enableReport.append("took: \(took)")
    let procs1 = pids(inBundle: bundlePath)
    let a0 = cpuSnapshot(procs1)
    Thread.sleep(forTimeInterval: 1.5)
    let a1 = cpuSnapshot(procs1)
    cpuAfter = String(format: "%.1f%% of one core (%d processes, 1.5 s)", cpuPercent(a0, a1, over: 1.5), procs1.count)
} else {
    enableReport.append(opts.noEnable ? "enable flags skipped (--no-enable)" : "enable flags not needed for this app (not Chromium/Electron/WebView2)")
}

// Helper processes (Teams and other web-shell apps) when the main tree is near-empty.
if (isTeams || isWebShell) && !stop.isSet {
    let (n, _) = quickCount(appEl)
    if n < 15 {
        enableReport.append("main process tree is near-empty (\(n) nodes); trying helper processes")
        for p in pids(inBundle: bundlePath) where p != mainPid && !stop.isSet {
            let el = AXUIElementCreateApplication(p)
            if shouldEnable { _ = setFlag(el, "AXManualAccessibility", p); Thread.sleep(forTimeInterval: 0.2) }
            let (hn, hw) = quickCount(el)
            let nm = (pidPath(p) ?? "?").split(separator: "/").last.map(String.init) ?? "?"
            enableReport.append("  helper pid \(p) \(nm): \(hn) nodes, \(hw) top-level elements")
            if hn >= 15 { targets.append((p, nm, el)) }
        }
        enableReport.append(targets.count > 1 ? "helpers with content are included in the walk" : "no helper process exposed a tree")
    }
}

// MARK: - Main loop

func writeJSON(_ obj: Any, to name: String) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: outDir.appendingPathComponent(name))
    }
}

let logURL = outDir.appendingPathComponent("changes.jsonl")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try? FileHandle(forWritingTo: logURL)
func logLine(_ o: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
        logHandle?.write(d + Data("\n".utf8))
    }
}

func walkAll(budget: TimeInterval) -> Tick {
    let start = Date()
    let w = Walker(maxNodes: opts.maxNodes, maxDepth: opts.maxDepth, deadline: start.addingTimeInterval(budget), collect: true)
    for t in targets {
        let prefix = t.pid == mainPid ? "" : "/helper\(t.pid)"
        var roots: [Node] = []
        for (i, r) in rootsFor(t.el).enumerated() {
            if let n = w.walk(r, parentPath: prefix, index: i, depth: 0, ctx: Ctx()) { roots.append(n) }
        }
        Walker.assignSigs(roots, parentSig: prefix)
        w.tick.roots += roots
    }
    w.tick.seconds = Date().timeIntervalSince(start)
    return w.tick
}

let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

func meta(_ t: Tick, _ time: Date) -> [String: Any] {
    ["bundleId": bundleId, "pid": Int(mainPid), "time": iso.string(from: time), "redacted": opts.redact,
     "capped": t.capped.sorted(), "nodes": t.nodeCount]
}

let runStart = Date()
let cpuRunStart = cpuSnapshot(pids(inBundle: bundlePath))
let selfStart = selfCPU()
var prev: Tick?
var tickNo = 0
var wroteStart = false

while !stop.isSet {
    let t0 = Date()
    var cur = walkAll(budget: opts.interval * 0.8)
    assignIds(&cur, prev: prev)
    let ts = iso.string(from: t0)
    col.ticks += 1
    col.maxNodesSeen = max(col.maxNodesSeen, cur.nodeCount)
    col.maxWalk = max(col.maxWalk, cur.seconds); col.sumWalk += cur.seconds
    col.axErrors += cur.axErrors; col.timeouts += cur.timeouts
    if cur.seconds > opts.interval { col.overrunTicks += 1 }
    if !cur.capped.isEmpty { col.cappedTicks += 1 }
    if prev != nil { col.matchedElement += cur.matchedElement; col.matchedStructure += cur.matchedStructure; col.fresh += cur.fresh }
    var changeCount = 0

    if let p = prev {
        let bothComplete = cur.capped.isEmpty && p.capped.isEmpty
        for node in cur.order {
            guard let old = p.flat[node.id] else { continue }
            var diffs: [String: [String]] = [:]
            for k in Set(node.attrs.keys).union(old.attrs.keys) {
                let a = old.attrs[k] ?? "<none>", b = node.attrs[k] ?? "<none>"
                if a != b { diffs[k] = [a, b] }
            }
            if diffs.isEmpty { continue }
            changeCount += 1
            col.changedNodes.insert(node.id)
            let role = node.raw["role"] ?? "?"
            for (k, ab) in diffs {
                col.totalChangeEvents += 1
                col.attrChangeCounts["\(role).\(k)", default: 0] += 1
                let fk = node.id + "|" + k
                var st = col.flipStats[fk] ?? (0, [], role, k)
                st.changes += 1; st.values.insert(ab[0]); st.values.insert(ab[1])
                col.flipStats[fk] = st
            }
            var line: [String: Any] = ["ts": ts, "tick": tickNo, "event": "changed", "id": node.id, "path": node.path, "role": role, "changes": diffs]
            if p.byKey[node.key] == nil { line["matchedBy"] = "structure" }
            logLine(line)
        }
        // Added/removed only when both walks were complete; a capped walk is a partial tree.
        if bothComplete {
            let added = cur.order.filter { p.flat[$0.id] == nil }
            let removed = p.order.filter { cur.flat[$0.id] == nil }
            for node in added.prefix(200) { logLine(["ts": ts, "tick": tickNo, "event": "added", "id": node.id, "path": node.path, "attrs": node.attrs]) }
            for node in removed.prefix(200) { logLine(["ts": ts, "tick": tickNo, "event": "removed", "id": node.id, "path": node.path, "role": node.raw["role"] ?? "?"]) }
            if added.count > 200 || removed.count > 200 {
                logLine(["ts": ts, "tick": tickNo, "event": "truncated", "added": added.count, "removed": removed.count])
            }
        }
    }
    if !wroteStart {
        writeJSON(["meta": meta(cur, t0), "tree": cur.roots.map { $0.json }], to: "snapshot-start.json")
        wroteStart = true
    }

    print(String(format: "tick %3d  nodes %5d  changed %3d  walk %.2fs", tickNo, cur.nodeCount, changeCount, cur.seconds)
          + (cur.capped.isEmpty ? "" : "  CAPPED(\(cur.capped.sorted().joined(separator: ",")))"))
    prev = cur; tickNo += 1

    if Date().timeIntervalSince(runStart) >= opts.seconds { break }
    let wake = t0.addingTimeInterval(opts.interval)
    while Date() < wake && !stop.isSet { Thread.sleep(forTimeInterval: 0.05) }
}

let runSecs = Date().timeIntervalSince(runStart)
let cpuRunEnd = cpuSnapshot(pids(inBundle: bundlePath))
let selfUsed = selfCPU() - selfStart

restoreFlags()   // before any file work, so a slow disk cannot delay it
if let l = prev {
    writeJSON(["meta": meta(l, Date()), "tree": l.roots.map { $0.json }], to: "snapshot-end.json")
}
try? logHandle?.close()

// MARK: - Summary

func top<K>(_ d: [K: Int], _ n: Int) -> [(K, Int)] where K: Hashable {
    Array(d.sorted { $0.value != $1.value ? $0.value > $1.value : "\($0.key)" < "\($1.key)" }.prefix(n))
}
func pct(_ a: Int, _ total: Int) -> String { total > 0 ? String(format: "%.0f%%", Double(a) / Double(total) * 100) : "n/a" }

say("")
say("=== ax-probe summary: \(bundleId) ===")
say("ticks: \(col.ticks) over \(String(format: "%.1f", runSecs)) s; nodes per walk: last \(prev?.nodeCount ?? 0), max \(col.maxNodesSeen)")
say(String(format: "walk time: avg %.2f s, max %.2f s; ticks over the interval: %d", col.ticks > 0 ? col.sumWalk / Double(col.ticks) : 0, col.maxWalk, col.overrunTicks))
say("capped walks: \(col.cappedTicks)/\(col.ticks)\(col.cappedTicks > 0 ? "  (raise --interval or --max-nodes, or lower --max-depth; capped walks are partial)" : "")")
say("AX errors: \(col.axErrors) (timeouts \(col.timeouts), \(axTimeout) s each)")
let idTotal = col.matchedElement + col.matchedStructure + col.fresh
say("node identity vs previous tick: \(pct(col.matchedElement, idTotal)) same AX element, \(pct(col.matchedStructure, idTotal)) re-created but structurally matched, \(pct(col.fresh, idTotal)) new"
    + (idTotal > 0 && col.matchedElement * 2 < idTotal ? "  (LOW: this app re-creates elements; diffs lean on structure)" : ""))
say("enable: " + enableReport.joined(separator: "\n        "))
say("target CPU before enabling: \(cpuBefore)")
say("target CPU after enabling:  \(cpuAfter)")
say(String(format: "target CPU over whole run (with probe walking): %.1f%% of one core", cpuPercent(cpuRunStart, cpuRunEnd, over: runSecs)))
say(String(format: "probe CPU time: %.2f s (%.1f%% of one core)", selfUsed, runSecs > 0 ? selfUsed / runSecs * 100 : 0))
say("change events: \(col.totalChangeEvents) across \(col.changedNodes.count) nodes")

say("\nName-like labels / participant rows (top 12, count = node-ticks seen):")
for (k, c) in top(col.labelCands, 12) { say("  \(c)x  \(k)") }
if col.labelCands.isEmpty { say("  none found") }

say("\nAttributes that changed most often (top 10, role.attribute):")
for (k, c) in top(col.attrChangeCounts, 10) { say("  \(c)x  \(k)") }
if col.attrChangeCounts.isEmpty { say("  no changes seen") }

say("\nFlip candidates: one node, one attribute, 2-4 distinct values, 2+ changes (top 10):")
let flips = col.flipStats.filter { $0.value.changes >= 2 && $0.value.values.count >= 2 && $0.value.values.count <= 4 && $0.value.attr != "frame" }
    .sorted { $0.value.changes > $1.value.changes }.prefix(10)
for (k, f) in flips {
    let id = k.split(separator: "|").first.map(String.init) ?? "?"
    say("  \(f.changes)x  \(f.role).\(f.attr) on \(id)  values: \(f.values.sorted().map { truncated($0, 40) }.joined(separator: " | "))")
}
if flips.isEmpty { say("  none") }

say("\nStatus / speaking words in any attribute (top 10):")
for (k, c) in top(col.statusHits, 10) { say("  \(c)x  \(k)") }
if col.statusHits.isEmpty { say("  none") }

say("\nCaptions (nodes mentioning caption/subtitle/transcript, and text beneath them; top 8):")
for (k, c) in top(col.captionHits, 8) { say("  \(c)x  \(k)") }
if col.captionHits.isEmpty { say("  none") }

say("\noutput: \(outDir.path)")
say(opts.redact ? "Redacted: text values are hashes (stable within this run only). Check before sharing anyway."
                : "This output contains real names. Keep it in /tmp. Do not commit or paste it.")
try? summaryLines.joined(separator: "\n").write(to: outDir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
exit(0)
