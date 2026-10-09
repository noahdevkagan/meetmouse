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
}

/// Deliberately separate from AIClient: screenshots and OCR never enter prompts.
@Observable @MainActor
final class VisualSpeakerCapture {
    private(set) var isRunning = false
    private(set) var isDiscovering = false
    private(set) var count = 0
    private(set) var status = ""
    private(set) var observations: [VisualSpeakerObservation] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    static let limit = 6
    static let automaticDefaultsKey = "automaticSpeakerSnapshots"

    struct Snapshot: Sendable {
        let name: String?
        let start: Date
        let end: Date
    }
    private enum CaptureError: Error { case windowUnavailable }
    private let findWindows: @MainActor () async throws -> [SpeakerWindowChoice]
    private let snapshot: @MainActor (SpeakerWindowChoice) async throws -> Snapshot
    private let pause: @MainActor (Duration) async throws -> Void

    init(findWindows: @escaping @MainActor () async throws -> [SpeakerWindowChoice] = VisualSpeakerCapture.windows,
         snapshot: @escaping @MainActor (SpeakerWindowChoice) async throws -> Snapshot = VisualSpeakerCapture.captureSnapshot,
         pause: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.findWindows = findWindows
        self.snapshot = snapshot
        self.pause = pause
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

    /// Only a unique recognized call window is safe to preselect. Window
    /// enumeration order or the frontmost browser is not evidence of a call.
    static func suggestedWindow(in windows: [SpeakerWindowChoice]) -> SpeakerWindowChoice? {
        let candidates = windows.filter { window in
            let info = WindowInfo(ownerName: window.app, title: window.title,
                                  ownerBundleID: window.bundleID)
            return MeetingWindowHeuristics.isZoomMeetingWindow(info)
                || MeetingWindowHeuristics.isSlackHuddleWindow(info)
                || MeetingWindowHeuristics.isMeetTabWindow(info)
                || MeetingWindowHeuristics.isHangoutsTabWindow(info)
                || MeetingWindowHeuristics.isFaceTimeCallWindow(info)
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Remembered opt-in authorizes discovery; ambiguity never starts capture.
    func startAutomatically(sessionStart: Date,
                            canStart: @escaping @MainActor () -> Bool,
                            onObservation: @escaping @MainActor () -> Void) {
        guard !isRunning, !isDiscovering, count < Self.limit, canStart() else { return }
        generation = UUID()
        let run = generation
        isDiscovering = true
        status = "Finding your meeting window…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let windows = try await self.findWindows()
                guard !Task.isCancelled, self.generation == run else { return }
                self.isDiscovering = false
                self.task = nil
                guard canStart() else {
                    self.status = "Automatic speaker snapshots skipped."
                    return
                }
                guard let window = Self.suggestedWindow(in: windows) else {
                    self.status = "No unique meeting window found. Choose a window to name speakers."
                    return
                }
                self.start(window: window, sessionStart: sessionStart, onObservation: onObservation)
            } catch {
                guard !Task.isCancelled, self.generation == run else { return }
                self.isDiscovering = false
                self.finish("Couldn’t find the meeting window. Check Screen Recording permission.")
            }
        }
    }

    func start(window: SpeakerWindowChoice, sessionStart: Date,
               onObservation: @escaping @MainActor () -> Void) {
        guard !isRunning, count < Self.limit else { return }
        task?.cancel()
        isDiscovering = false
        generation = UUID()
        let run = generation
        observations = []
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
                    self.status = "Speaker snapshots \(self.count)/\(Self.limit) · on-device"
                    if self.count < Self.limit { try await self.pause(.seconds(15)) }
                } catch {
                    guard !Task.isCancelled, self.generation == run else { return }
                    self.finish(error is CaptureError
                        ? "Window changed or hidden. Screenshot assistance stopped."
                        : "Couldn’t read this window. Check Screen Recording permission.")
                    return
                }
            }
            guard let self, self.generation == run, !Task.isCancelled else { return }
            self.finish(self.observations.isEmpty
                ? "No speaker names read. Show participant names and Zoom’s active-speaker outline."
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
        isDiscovering = false
        observations = []
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
        let name = try await Task.detached(priority: .utility) {
            try VisualSpeakerOCR.activeName(in: image)
        }.value
        return Snapshot(name: name, start: start, end: end)
    }
}

/// Conservative first adapter: a complete green/yellow active-speaker tile
/// with exactly one readable name along its bottom edge (Zoom-style gallery).
/// No face recognition, largest-tile guesses, chat authors, or participant lists.
enum VisualSpeakerOCR {
    struct Line {
        let text: String
        let confidence: Float
        let rect: CGRect // normalized, top-left origin
    }

    static func activeName(in image: CGImage) throws -> String? {
        let tiles = highlightedTiles(in: image)
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

    static func cleanName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
    static func highlightedTiles(in image: CGImage) -> [CGRect] {
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
            return g > 130 && g > b + 65 && (g > r + 35 || (r > 170 && abs(r - g) < 85))
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
