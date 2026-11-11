import AppKit
import ScreenCaptureKit
import Vision
import Observation

struct SpeakerWindowChoice: Identifiable, Sendable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    /// Owning app's bundle id (nil when unknown) — the window heuristics
    /// match on it ahead of the drifting display name.
    var bundleID: String? = nil

    var platformName: String {
        let info = WindowInfo(ownerName: app, title: title, ownerBundleID: bundleID)
        if MeetingWindowHeuristics.isMeetTabWindow(info) { return "Google Meet" }
        if MeetingWindowHeuristics.isZoomMeetingWindow(info) { return "Zoom" }
        if MeetingWindowHeuristics.isSlackHuddleWindow(info) { return "Slack" }
        if MeetingWindowHeuristics.isFaceTimeCallWindow(info) { return "FaceTime" }
        if MeetingWindowHeuristics.isTeamsMeetingWindow(info) { return "Microsoft Teams" }
        return app
    }

    var highlightStyle: VisualSpeakerOCR.HighlightStyle {
        let info = WindowInfo(ownerName: app, title: title, ownerBundleID: bundleID)
        if MeetingWindowHeuristics.isMeetTabWindow(info) { return .googleMeet }
        // Teams uses neither outline colour: nothing readable yet.
        if MeetingWindowHeuristics.isTeamsMeetingWindow(info) { return .unsupported }
        return .zoom
    }
}

/// Deliberately separate from AIClient: screenshots and OCR never enter prompts.
@Observable @MainActor
final class VisualSpeakerCapture {
    private(set) var isRunning = false
    private(set) var isDiscovering = false
    private(set) var count = 0
    private(set) var status = ""
    private(set) var observations: [VisualSpeakerObservation] = []
    private(set) var rosters: [VisualRosterObservation] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    static let limit = 6
    static let automaticDefaultsKey = "automaticSpeakerSnapshots"

    struct Snapshot: Sendable {
        let name: String?
        let start: Date
        let end: Date
        /// Other tiles aligned with the user's own; nil when theirs wasn't found.
        var roster: [String]? = nil
    }
    enum CaptureError: Error { case windowUnavailable }
    private let findWindows: @MainActor () async throws -> [SpeakerWindowChoice]
    private let snapshot: @MainActor (SpeakerWindowChoice) async throws -> Snapshot
    private let pause: @MainActor (Duration) async throws -> Void
    private let windowExists: @MainActor (CGWindowID) -> Bool

    init(findWindows: @escaping @MainActor () async throws -> [SpeakerWindowChoice] = VisualSpeakerCapture.windows,
         snapshot: @escaping @MainActor (SpeakerWindowChoice) async throws -> Snapshot = VisualSpeakerCapture.captureSnapshot,
         pause: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         windowExists: @escaping @MainActor (CGWindowID) -> Bool = VisualSpeakerCapture.windowExists) {
        self.findWindows = findWindows
        self.snapshot = snapshot
        self.pause = pause
        self.windowExists = windowExists
    }

    /// Any window with this id, on screen or not (minimized, other Space).
    /// Metadata only; no pixels.
    nonisolated static func windowExists(_ id: CGWindowID) -> Bool {
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        return rows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
    }

    nonisolated static func windows() async throws -> [SpeakerWindowChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard window.windowLayer == 0, window.frame.width >= 240, window.frame.height >= 160,
                  let app = window.owningApplication,
                  app.processID != ProcessInfo.processInfo.processIdentifier,
                  let title = window.title, !title.isEmpty else { return nil }
            return SpeakerWindowChoice(id: window.windowID, pid: app.processID,
                                       app: app.applicationName, title: title,
                                       bundleID: app.bundleIdentifier)
        }.sorted { ($0.app, $0.title) < ($1.app, $1.title) }
    }

    static func meetingWindows(in windows: [SpeakerWindowChoice]) -> [SpeakerWindowChoice] {
        windows.filter { window in
            let info = WindowInfo(ownerName: window.app, title: window.title,
                                  ownerBundleID: window.bundleID)
            return MeetingWindowHeuristics.isZoomMeetingWindow(info)
                || MeetingWindowHeuristics.isSlackHuddleWindow(info)
                || MeetingWindowHeuristics.isMeetTabWindow(info)
                || MeetingWindowHeuristics.isHangoutsTabWindow(info)
                || MeetingWindowHeuristics.isFaceTimeCallWindow(info)
                || MeetingWindowHeuristics.isTeamsMeetingWindow(info)
        }
    }

    /// Only a unique recognized call window is safe to preselect.
    static func suggestedWindow(in windows: [SpeakerWindowChoice]) -> SpeakerWindowChoice? {
        let candidates = meetingWindows(in: windows)
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Used only after the user explicitly asks to switch to their call.
    /// Do not skip an unrelated front browser window to pick a call behind it.
    static func foregroundMeetingWindow(in windows: [SpeakerWindowChoice],
                                        frontmostPID: pid_t?,
                                        orderedWindowIDs: [CGWindowID]) -> SpeakerWindowChoice? {
        guard let frontmostPID,
              let frontID = orderedWindowIDs.first,
              let front = windows.first(where: { $0.id == frontID && $0.pid == frontmostPID }),
              meetingWindows(in: [front]).count == 1 else { return nil }
        return front
    }

    static func foregroundMeetingWindow(in windows: [SpeakerWindowChoice]) -> SpeakerWindowChoice? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = rows.compactMap { row -> CGWindowID? in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return foregroundMeetingWindow(in: windows, frontmostPID: pid, orderedWindowIDs: ids)
    }

    /// Quiet re-check cadence while no unique call window exists. The session
    /// often starts seconds before the call window does (2026-11-10); the
    /// last delay repeats until the session ends.
    static let discoveryDelays: [Duration] = [.seconds(2), .seconds(3), .seconds(5), .seconds(8),
                                              .seconds(13), .seconds(20), .seconds(30)]

    /// Remembered opt-in authorizes discovery; ambiguity never starts capture.
    /// Keeps re-checking until exactly one recognized window exists or the
    /// session ends (`stop`, or `canStart` turning false).
    func startAutomatically(sessionStart: Date,
                            canStart: @escaping @MainActor () -> Bool,
                            onObservation: @escaping @MainActor () -> Void) {
        guard !isRunning, !isDiscovering, count < Self.limit, canStart() else { return }
        generation = UUID()
        observations = []
        rosters = []
        discover(sessionStart: sessionStart, canStart: canStart, onObservation: onObservation)
    }

    /// Two or more recognized call windows: the user is asked to choose.
    private(set) var needsWindowChoice = false
    private var lastDiscoveryNote = ""

    private func discover(sessionStart: Date,
                          canStart: @escaping @MainActor () -> Bool,
                          onObservation: @escaping @MainActor () -> Void) {
        let run = generation
        isDiscovering = true
        needsWindowChoice = false
        lastDiscoveryNote = ""
        status = "Finding your meeting window…"
        // Self stays weak across the sleeps: a dropped owner ends the loop.
        let pause = self.pause
        task = Task { [weak self] in
            var attempt = 0
            while await self?.discoveryStep(run: run, attempt: attempt, sessionStart: sessionStart,
                                            canStart: canStart, onObservation: onObservation) == true {
                let delays = VisualSpeakerCapture.discoveryDelays
                do { try await pause(delays[min(attempt, delays.count - 1)]) } catch { return }
                attempt += 1
            }
        }
    }

    /// One window listing. Returns true to look again after a pause.
    private func discoveryStep(run: UUID, attempt: Int, sessionStart: Date,
                               canStart: @escaping @MainActor () -> Bool,
                               onObservation: @escaping @MainActor () -> Void) async -> Bool {
        guard !Task.isCancelled, generation == run else { return false }
        let windows: [SpeakerWindowChoice]
        do {
            windows = try await findWindows()
        } catch {
            guard !Task.isCancelled, generation == run else { return false }
            mclog("speaker-snapshots discovery: window list failed (attempt \(attempt + 1))")
            endDiscovery()
            finish("Couldn’t find the meeting window. Check Screen Recording permission.")
            return false
        }
        guard !Task.isCancelled, generation == run else { return false }
        guard canStart() else {
            endDiscovery()
            task = nil
            status = "Automatic speaker snapshots skipped."
            return false
        }
        let calls = Self.meetingWindows(in: windows)
        // Counts and platform names only: titles can carry people's names.
        let callAppOther = windows.filter { w in
            let info = WindowInfo(ownerName: w.app, title: w.title, ownerBundleID: w.bundleID)
            return (MeetingWindowHeuristics.isZoomOwned(info) || MeetingWindowHeuristics.isTeamsOwned(info)
                    || MeetingWindowHeuristics.isSlackOwned(info) || MeetingWindowHeuristics.isFaceTimeOwned(info))
                && !calls.contains(w)
        }.count
        let reason = calls.isEmpty ? (callAppOther > 0 ? "no call window yet (call app open)" : "no call app window")
            : calls.count == 1 ? "unique" : "ambiguous"
        let note = "speaker-snapshots discovery: callWindows=\(calls.count) "
            + "[\(calls.map(\.platformName).sorted().joined(separator: ","))] "
            + "callAppOtherWindows=\(callAppOther) -> \(reason)"
        if note != lastDiscoveryNote {
            mclog("\(note) (attempt \(attempt + 1), windows=\(windows.count))")
            lastDiscoveryNote = note
        }
        guard calls.count == 1, let window = calls.first else {
            // Zero: stay quiet. Two or more: ask, and keep looking so the
            // question withdraws itself once only one call is left.
            needsWindowChoice = calls.count > 1
            status = needsWindowChoice ? "Choose your call to help name speakers."
                                       : "Finding your meeting window…"
            return true
        }
        endDiscovery()
        task = nil
        if window.highlightStyle == .unsupported {
            // Recognized, but nothing to read: no screenshot is worth taking.
            mclog("speaker-snapshots discovery: \(window.platformName) has no name reader; not capturing")
            status = "\(window.platformName) names can’t be read yet. Click a speaker label to name them."
            return false
        }
        beginCapture(window: window, sessionStart: sessionStart,
                     onObservation: onObservation, canStart: canStart)
        return false
    }

    private func endDiscovery() {
        isDiscovering = false
        needsWindowChoice = false
    }

    func start(window: SpeakerWindowChoice, sessionStart: Date,
               onObservation: @escaping @MainActor () -> Void) {
        guard !isRunning, count < Self.limit else { return }
        task?.cancel()
        endDiscovery()
        generation = UUID()
        observations = []
        rosters = []
        beginCapture(window: window, sessionStart: sessionStart,
                     onObservation: onObservation, canStart: nil)
    }

    /// `canStart` is set only in automatic mode, where a pinned window that
    /// no longer exists anywhere may hand back to discovery.
    private func beginCapture(window: SpeakerWindowChoice, sessionStart: Date,
                              onObservation: @escaping @MainActor () -> Void,
                              canStart: (@MainActor () -> Bool)?) {
        guard !isRunning, count < Self.limit else { return }
        let run = generation
        isRunning = true
        status = "Speaker snapshots 0/\(Self.limit) · on-device"
        task = Task { [weak self] in
            // Let the consent sheet disappear; never activate or move the call.
            do { try await self?.pause(.seconds(3)) } catch { return }
            while !Task.isCancelled, let self, self.generation == run, self.count < Self.limit {
                do {
                    // Count requests, including failures: the meeting cap is hard.
                    self.count += 1
                    let snapshot = try await self.snapshot(window)
                    guard !Task.isCancelled, self.generation == run else { return }
                    if let name = snapshot.name, snapshot.end.timeIntervalSince(snapshot.start) <= 1 {
                        self.observations.append(.init(name: name, start: snapshot.start.timeIntervalSince(sessionStart),
                                                       end: snapshot.end.timeIntervalSince(sessionStart)))
                        onObservation()
                    }
                    if let roster = snapshot.roster {
                        self.rosters.append(.init(names: roster, time: snapshot.start.timeIntervalSince(sessionStart)))
                        if !roster.isEmpty { onObservation() }
                    }
                    self.status = "Speaker snapshots \(self.count)/\(Self.limit) · on-device"
                    if self.count < Self.limit { try await self.pause(.seconds(15)) }
                } catch {
                    guard !Task.isCancelled, self.generation == run else { return }
                    // Never swap a pinned window that still exists (retitled
                    // tab, minimized, other Space). Only when it is closed may
                    // automatic mode look for the next unique call window;
                    // the six-shot budget and evidence so far carry over.
                    if error is CaptureError, let canStart, canStart(), self.count < Self.limit,
                       !self.windowExists(window.id) {
                        mclog("speaker-snapshots: pinned window closed, resuming discovery")
                        self.isRunning = false
                        self.discover(sessionStart: sessionStart, canStart: canStart,
                                      onObservation: onObservation)
                        return
                    }
                    self.finish(error is CaptureError
                        ? "Window changed or hidden. Screenshot assistance stopped."
                        : "Couldn’t read this window. Check Screen Recording permission.")
                    return
                }
            }
            guard let self, self.generation == run, !Task.isCancelled else { return }
            self.finish(self.observations.isEmpty && !self.rosters.contains(where: { !$0.names.isEmpty })
                ? "No speaker names read. Show participant names for the next meeting, or click a speaker label to name them now."
                : "Snapshots finished. Names were read; only reliable voice matches become suggestions.")
        }
    }

    private func finish(_ message: String) {
        isRunning = false
        status = message
        task = nil
    }

    func stop(reset: Bool = false) {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
        endDiscovery()
        observations = []
        rosters = []
        status = reset ? "" : "Screenshot assistance stopped"
        if reset { count = 0 }
    }

    nonisolated private static func captureSnapshot(window: SpeakerWindowChoice) async throws -> Snapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        // Pin BOTH the window and its original title/owner. Browser tab
        // changes, closed/minimized windows stop the run; no fallback.
        guard let selected = content.windows.first(where: {
            $0.windowID == window.id && $0.owningApplication?.processID == window.pid
                && $0.title == window.title && $0.isOnScreen && $0.windowLayer == 0
        }) else { throw CaptureError.windowUnavailable }
        let filter = SCContentFilter(desktopIndependentWindow: selected)
        let configuration = SCStreamConfiguration()
        let scale = min(1.5, 1600 / max(selected.frame.width, selected.frame.height))
        configuration.width = max(1, Int(selected.frame.width * scale))
        configuration.height = max(1, Int(selected.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.capturesAudio = false
        let start = Date()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let end = Date()
        try Task.checkCancellation()
        // The image stays only in this scope + the local OCR task. No file,
        // pasteboard, telemetry, logs, or AI provider gets a copy.
        let selfName = VisualSpeakerOCR.selfName()
        let style = window.highlightStyle
        let (name, roster) = try await Task.detached(priority: .utility) {
            // Meet's "You" tile and dynamic layouts need a separate roster
            // adapter. Until then, require its active-speaker outline.
            (try VisualSpeakerOCR.activeName(in: image, style: style),
             style == .zoom ? try VisualSpeakerOCR.remoteRoster(in: image, selfName: selfName) : nil)
        }.value
        return Snapshot(name: name, start: start, end: end, roster: roster)
    }
}

/// Require a complete active-speaker outline and exactly one readable name
/// along its bottom edge: green/yellow for Zoom, blue for Google Meet.
/// No face recognition, largest-tile guesses, chat authors, or participant lists.
enum VisualSpeakerOCR {
    enum HighlightStyle: Sendable {
        case zoom
        case googleMeet
        /// Recognized call window with no outline adapter (Teams): never
        /// worth a screenshot on its own.
        case unsupported
    }

    struct Line {
        let text: String
        let confidence: Float
        let rect: CGRect // normalized, top-left origin
    }

    static func activeName(in image: CGImage, style: HighlightStyle = .zoom) throws -> String? {
        let tiles = highlightedTiles(in: image, style: style)
        guard tiles.count == 1, let tile = tiles.first else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        // Limit OCR itself to the lower part of the highlighted tile.
        let band = CGRect(x: tile.minX, y: tile.maxY - tile.height * 0.22,
                          width: tile.width, height: tile.height * 0.22)
        request.regionOfInterest = CGRect(x: band.minX, y: 1 - band.maxY,
                                           width: band.width, height: band.height)
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision reports coordinates relative to the request ROI.
            let box = observation.boundingBox
            return Line(text: candidate.string, confidence: candidate.confidence,
                        rect: CGRect(x: band.minX + box.minX * band.width,
                                     y: band.minY + (1 - box.maxY) * band.height,
                                     width: box.width * band.width, height: box.height * band.height))
        }
        return name(in: tile, lines: lines)
    }

    static func name(in tile: CGRect, lines: [Line]) -> String? {
        let candidates = lines.filter {
            $0.confidence >= 0.8 && tile.contains($0.rect)
                && $0.rect.minY >= tile.maxY - tile.height * 0.22
                && $0.rect.height < tile.height * 0.15
        }.compactMap { cleanName($0.text) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static let selfNameDefaultsKey = "speakerSelfName"

    /// The user's own tile label anchors roster reading. The macOS account
    /// name is only a fallback: it is often a household or device name.
    static func selfName() -> String {
        let saved = UserDefaults.standard.string(forKey: selfNameDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? NSFullUserName() : saved
    }

    /// One-on-one fallback for layouts without an active-speaker outline
    /// (Zoom's screen-share filmstrip, a two-tile gallery). Says who is
    /// present, not who is talking. nil when the user's own label is absent.
    static func remoteRoster(in image: CGImage, selfName: String) throws -> [String]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let luma = lumaPixels(image) else { return nil }
        let w = image.width, h = image.height
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            let line = Line(text: candidate.string, confidence: candidate.confidence,
                            rect: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            // Zoom labels are white text on a dark pill; shared documents are
            // mostly dark-on-light. Measured on a real call: labels ~65% dark
            // / ~17% bright inside the text box, doc text ~10% / ~76%.
            let x0 = max(0, Int(line.rect.minX * Double(w))), x1 = min(w, Int(line.rect.maxX * Double(w)))
            let y0 = max(0, Int(line.rect.minY * Double(h))), y1 = min(h, Int(line.rect.maxY * Double(h)))
            guard x1 > x0, y1 > y0 else { return nil }
            var dark = 0, bright = 0
            for y in y0..<y1 { for x in x0..<x1 {
                let l = luma[y * w + x]
                if l < 110 { dark += 1 } else if l > 170 { bright += 1 }
            } }
            let area = Double((x1 - x0) * (y1 - y0))
            return Double(dark) / area >= 0.45 && Double(bright) / area >= 0.1 ? line : nil
        }
        return roster(lines: lines, selfName: selfName, aspect: Double(w) / Double(h))
    }

    private static func lumaPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Anchor on the user's own label; keep only labels in its column
    /// (filmstrip) or row (gallery) at a similar text size. Shared screens
    /// and toolbars carry plenty of name-like text that never lines up.
    static func roster(lines: [Line], selfName: String, aspect: Double) -> [String]? {
        let labels = lines.filter { $0.confidence >= 0.8 }.compactMap { line in
            labelName(line.text).map { (name: $0, rect: line.rect) }
        }
        let mine = labels.filter { isSelf($0.name, selfName) }
        guard mine.count == 1, let anchor = mine.first?.rect else { return nil }
        // Half a text height in each axis (rects are normalized per axis).
        let dy = anchor.height * 0.5, dx = dy / aspect
        let others = labels.filter {
            !isSelf($0.name, selfName) && abs($0.rect.height - anchor.height) <= anchor.height * 0.3
        }
        // A filmstrip column wins; only without one can a gallery row count,
        // so shared text level with the user's tile never joins a filmstrip.
        let column = others.filter { abs($0.rect.minX - anchor.minX) <= dx }
        let aligned = column.isEmpty ? others.filter { abs($0.rect.midY - anchor.midY) <= dy } : column
        var seen = Set<String>()
        return aligned.map(\.name).filter { seen.insert(fold($0)).inserted }
    }

    /// Zoom prefixes muted tiles with a mic icon that OCR reads as a symbol.
    static func labelName(_ raw: String) -> String? {
        let words = raw.split(separator: " ")
        return cleanName(words.drop { !$0.contains(where: \.isLetter) }.joined(separator: " "))
    }

    /// "noah kagan", "Noah" and "Noah K" are all the user "Noah Kagan".
    static func isSelf(_ label: String, _ selfName: String) -> Bool {
        let a = fold(label).split(separator: " "), b = fold(selfName).split(separator: " ")
        guard let first = a.first, first == b.first else { return false }
        return zip(a, b).allSatisfy { $0.hasPrefix($1) || $1.hasPrefix($0) }
    }

    static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Sans-serif labels draw capital I and lowercase l alike: a real Zoom call
    /// misread a guest's name this way. A leading l before a consonant is not a
    /// name beyond Lloyd and Llewellyn; "lan" is the one vowel case common enough.
    static func restoringCapitalI(_ word: Substring) -> String {
        guard word.first == "l", let next = word.dropFirst().first, next.isASCII, next.isLowercase,
              !"aeiouy".contains(next) || word == "lan",
              !word.hasPrefix("lloyd"), !word.hasPrefix("llew") else { return String(word) }
        return "I" + word.dropFirst()
    }

    static func cleanName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.split(separator: " ").map(restoringCapitalI).joined(separator: " ")
        guard (2...40).contains(name.count) else { return nil }
        let words = name.split(separator: " ")
        guard (1...4).contains(words.count), words.allSatisfy({ word in
            word.first?.isLetter == true && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }
        }) else { return nil }
        let blocked: Set<String> = ["you", "me", "host", "mute", "unmute", "speaking", "talking", "zoom",
                                    "participants", "chat", "recording", "share", "screen", "meeting", "speaker"]
        guard !words.contains(where: { blocked.contains($0.lowercased()) }) else { return nil }
        return name
    }

    /// Find long colored horizontal edges, then require matching bottom AND
    /// both side edges (square or rounded corners). Reject whole-window
    /// sharing borders and multiple tiles.
    static func highlightedTiles(in image: CGImage, style: HighlightStyle = .zoom) -> [CGRect] {
        let w = image.width, h = image.height
        guard w >= 240, h >= 160 else { return [] }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [] }
        func colored(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            switch style {
            case .zoom:
                return g > 130 && g > b + 65 && (g > r + 35 || (r > 170 && abs(r - g) < 85))
            case .unsupported:
                return false
            case .googleMeet:
                // Meet's light/dark blue outlines. Keep this scoped to Meet:
                // blue UI frames in other apps are not speaker evidence.
                return b > 150 && g > 70 && b > r + 35 && b > g + 15
            }
        }
        var result: [CGRect] = []
        for y in 2..<(h - 80) {
            var x = 2
            while x < w - 120 {
                guard colored(x, y) else { x += 1; continue }
                let left = x
                while x < w && colored(x, y) { x += 1 }
                let right = x - 1
                // Lower rows of a rounded top border run wider; they belong
                // to the tile already found, not a second highlight.
                guard right - left >= 120,
                      !(colored(left, y - 1) && colored(right, y - 1)),
                      !result.contains(where: { abs($0.minY * Double(h) - Double(y)) < 8
                          && Double(left + 8) >= $0.minX * Double(w)
                          && Double(right - 8) <= $0.maxX * Double(w) }) else { continue }
                for bottom in (y + 80)..<h {
                    guard colored(left, bottom), colored(right, bottom) else { continue }
                    let horizontal = Array(stride(from: left, through: right, by: 4))
                    let bottomScore = Double(horizontal.filter { colored($0, bottom) }.count) / Double(horizontal.count)
                    guard bottomScore > 0.95 else { continue }
                    // Rounded corners (Zoom's tiles) end the straight top run
                    // inside the tile: find each side border at mid-height, up
                    // to a corner radius outward, and skip the corner arcs.
                    let mid = (y + bottom) / 2, reach = min(40, (right - left) / 4)
                    guard let sideLeft = stride(from: left, through: max(0, left - reach), by: -1)
                              .first(where: { colored($0, mid) }),
                          let sideRight = stride(from: right, through: min(w - 1, right + reach), by: 1)
                              .first(where: { colored($0, mid) }) else { continue }
                    let inset = max(left - sideLeft, sideRight - right) + 2
                    guard bottom - y > 2 * inset + 8 else { continue }
                    let vertical = Array(stride(from: y + inset, through: bottom - inset, by: 4))
                    let sideScore = Double(vertical.filter { colored(sideLeft, $0) && colored(sideRight, $0) }.count) / Double(vertical.count)
                    guard sideScore > 0.95 else { continue }
                    let rect = CGRect(x: Double(sideLeft) / Double(w), y: Double(y) / Double(h),
                                      width: Double(sideRight - sideLeft) / Double(w), height: Double(bottom - y) / Double(h))
                    // Window-sized green borders often mean screen sharing.
                    guard rect.width * rect.height < 0.85 else { break }
                    result.append(rect)
                    if result.count > 1 { return result }
                    break
                }
            }
        }
        return result
    }
}
