import AppKit

@MainActor
func visualSpeakerChecks() async {
    let zoom = SpeakerWindowChoice(id: 1, pid: 1, app: "zoom.us", title: "Zoom Meeting")
    let idle = SpeakerWindowChoice(id: 2, pid: 1, app: "zoom.us", title: "Zoom Workplace")
    let browser = SpeakerWindowChoice(id: 3, pid: 2, app: "Google Chrome", title: "Inbox — Gmail")
    let meet = SpeakerWindowChoice(id: 4, pid: 2, app: "Google Chrome", title: "Meet – Team sync")
    let fake = SpeakerWindowChoice(id: 5, pid: 3, app: "Notes", title: "Zoom Meeting")
    check(VisualSpeakerCapture.suggestedWindow(in: [idle, browser, zoom, fake]) == zoom,
          "visual: auto-select unique meeting without unrelated or idle windows")
    check(VisualSpeakerCapture.suggestedWindow(in: [browser, meet]) == meet,
          "visual: auto-select recognized browser meeting")
    check(VisualSpeakerCapture.suggestedWindow(in: [zoom, meet]) == nil,
          "visual: multiple meeting windows require a choice")
    check(VisualSpeakerCapture.suggestedWindow(in: [idle, browser, fake]) == nil,
          "visual: unrelated window never selected as fallback")
    check(VisualSpeakerCapture.suggestedWindow(in: []) == nil,
          "visual: no visible windows means no automatic capture target")
    check(VisualSpeakerCapture.suggestedWindow(in: [zoom, .init(id: 6, pid: 1, app: "zoom.us", title: "Zoom Meeting")]) == nil,
          "visual: identical titles do not disambiguate separate windows")
    // Zoom Workplace 7.x: SCK names the app "Zoom"; the bundle id still says Zoom.
    let zoom7 = SpeakerWindowChoice(id: 7, pid: 4, app: "Zoom", title: "Zoom Meeting", bundleID: "us.zoom.xos")
    let zoom7Home = SpeakerWindowChoice(id: 8, pid: 4, app: "Zoom", title: "Zoom Workplace", bundleID: "us.zoom.xos")
    check(VisualSpeakerCapture.suggestedWindow(in: [zoom7Home, browser, zoom7]) == zoom7,
          "visual: auto-select Zoom 7 meeting window by bundle id")

    let observations = [VisualSpeakerObservation(name: "Sarah", start: 10, end: 10.1),
                        VisualSpeakerObservation(name: "Sarah", start: 25, end: 25.1)]
    let segments = [SpeakerSegment(speaker: "Them 1", start: 5, end: 30)]
    func matches(_ obs: [VisualSpeakerObservation] = [], _ segs: [SpeakerSegment]? = nil,
                 _ local: [Utterance] = []) -> [(label: String, name: String)] {
        VisualSpeakerEvidence.matches(obs, segments: segs ?? segments, localSpeech: local)
    }
    check(matches(observations).first?.name == "Sarah", "visual: repeated aligned evidence proposes name")
    check(matches([observations[0], observations[0]]).isEmpty, "visual: duplicate frame cannot confirm a name")
    check(matches([observations[0]]).isEmpty, "visual: one screenshot cannot name a speaker")
    check(matches(observations, []).isEmpty, "visual: wait for finalized audio")
    check(matches(observations, [SpeakerSegment(speaker: "Them", start: 0, end: 40)]).isEmpty,
          "visual: never bind undiarized remote audio")
    check(matches(observations, [SpeakerSegment(speaker: "Speaker 1", start: 0, end: 40)]).isEmpty,
          "visual: never bind mixed microphone audio")
    check(matches(observations, segments + [SpeakerSegment(speaker: "Them 2", start: 24, end: 26)]).isEmpty,
          "visual: overlapping voices veto evidence")
    check(matches(observations, nil, [Utterance(t: 24, speaker: "You", text: "Hello", endT: 26)]).isEmpty,
          "visual: local speaker overlap vetoes evidence")
    check(matches(observations, [SpeakerSegment(speaker: "Them 1", start: 10, end: 30)]).isEmpty,
          "visual: speaker transition margin required")
    check(matches(observations + [.init(name: "Priya", start: 20, end: 20.1)]).isEmpty,
          "visual: conflicting names veto mapping")
    check(matches(observations + [.init(name: "Sarah", start: 40, end: 40.1)],
                  segments + [.init(speaker: "Them 2", start: 35, end: 45)]).isEmpty,
          "visual: same name across voices is ambiguous")
    check(matches([.init(name: "Sarah", start: 10, end: 12), observations[1]]).isEmpty,
          "visual: slow capture discarded")
    check(matches(observations, [SpeakerSegment(speaker: "Priya", start: 0, end: 40)]).isEmpty,
          "visual: revised or named segments remove old match")

    let tile = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
    let line = VisualSpeakerOCR.Line(text: "Sarah", confidence: 0.99,
                                    rect: CGRect(x: 0.12, y: 0.45, width: 0.1, height: 0.03))
    check(VisualSpeakerOCR.name(in: tile, lines: [line]) == "Sarah", "visual: bottom tile name accepted")
    check(VisualSpeakerOCR.name(in: tile, lines: [line, line]) == nil, "visual: multiple text labels rejected")
    check(VisualSpeakerOCR.name(in: tile, lines: [.init(text: "Sarah", confidence: 0.5, rect: line.rect)]) == nil,
          "visual: weak OCR rejected")
    check(VisualSpeakerOCR.name(in: tile, lines: [.init(text: "Sarah", confidence: 0.99,
                                                     rect: CGRect(x: 0.6, y: 0.45, width: 0.1, height: 0.03))]) == nil,
          "visual: chat and outside names ignored")
    check(VisualSpeakerOCR.cleanName("Sarah (You)") == nil && VisualSpeakerOCR.cleanName("Share Screen") == nil,
          "visual: self labels and controls rejected")
    check(VisualSpeakerOCR.cleanName("María O’Neill") == "María O’Neill", "visual: international names retained")

    func fixture(_ rects: [CGRect], names: Bool = true, yellow: Bool = false, radius: CGFloat = 0) -> CGImage {
        let context = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8,
                                bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for rect in rects {
            context.setStrokeColor(NSColor(calibratedRed: yellow ? 0.95 : 0.2, green: 0.9, blue: 0.15, alpha: 1).cgColor)
            context.setLineWidth(3)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
            if names {
                ("Sarah" as NSString).draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 10),
                                           withAttributes: [.font: NSFont.systemFont(ofSize: 20),
                                                            .foregroundColor: NSColor.white])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
    let rect = CGRect(x: 40, y: 150, width: 340, height: 230)
    let image = fixture([rect])
    let tiles = VisualSpeakerOCR.highlightedTiles(in: image)
    check(tiles.count == 1 && abs((tiles.first?.minY ?? 0) - 0.24) < 0.02,
          "visual: pixel border geometry uses top-left coordinates", "\(tiles)")
    do {
        let name = try VisualSpeakerOCR.activeName(in: image)
        check(name == "Sarah", "visual: real Vision OCR reads synthetic highlighted tile", "\(name ?? "nil")")
        check(try VisualSpeakerOCR.activeName(in: fixture([rect], yellow: true)) == "Sarah",
              "visual: yellow active-speaker outline supported")
        for radius: CGFloat in [8, 12, 20] {
            let rounded = fixture([rect], radius: radius)
            let name = try VisualSpeakerOCR.activeName(in: rounded)
            check(VisualSpeakerOCR.highlightedTiles(in: rounded).count == 1 && name == "Sarah",
                  "visual: rounded \(Int(radius))px outline (Zoom tiles) read",
                  "\(VisualSpeakerOCR.highlightedTiles(in: rounded))")
        }
        check(try VisualSpeakerOCR.activeName(in: fixture([rect, rect.offsetBy(dx: 380, dy: 0)], radius: 12)) == nil,
              "visual: multiple rounded highlights rejected")
        check(try VisualSpeakerOCR.activeName(in: fixture([])) == nil, "visual: no highlight no name")
        check(try VisualSpeakerOCR.activeName(in: fixture([rect], names: false)) == nil,
              "visual: empty tile no name")
        check(try VisualSpeakerOCR.activeName(in: fixture([rect, rect.offsetBy(dx: 380, dy: 0)])) == nil,
              "visual: multiple highlights rejected")
        check(try VisualSpeakerOCR.activeName(in: fixture([CGRect(x: 4, y: 4, width: 792, height: 492)])) == nil,
              "visual: screen-sharing perimeter rejected")
    } catch { check(false, "visual: OCR fixture", String(describing: error)) }

    let capture = VisualSpeakerCapture()
    let window = SpeakerWindowChoice(id: 0, pid: 0, app: "Synthetic", title: "Synthetic")
    capture.start(window: window, sessionStart: Date()) { check(false, "visual: cancelled callback") }
    capture.stop()
    check(!capture.isRunning && capture.observations.isEmpty && capture.count == 0,
          "visual: cancel before first shot clears evidence and disables capture")
    capture.stop(reset: true)
    check(capture.status.isEmpty && capture.count == 0, "visual: next meeting starts opt-out")
    var requests = 0
    var callbacks = 0
    let bounded = VisualSpeakerCapture(snapshot: { _ in
        requests += 1
        return .init(name: "Sarah", start: Date(), end: Date())
    }, pause: { _ in })
    bounded.start(window: window, sessionStart: Date()) { callbacks += 1 }
    for _ in 0..<100 where bounded.isRunning { await Task.yield() }
    check(requests == 6 && bounded.count == 6 && !bounded.isRunning && callbacks == 6,
          "visual: six-shot hard cap ends capture")
    bounded.stop()
    bounded.start(window: window, sessionStart: Date()) { callbacks += 1 }
    await Task.yield()
    check(requests == 6 && !bounded.isRunning, "visual: restart cannot exceed meeting cap")

    var automaticShots = 0
    let automatic = VisualSpeakerCapture(findWindows: { [zoom] }, snapshot: { _ in
        automaticShots += 1
        return .init(name: nil, start: Date(), end: Date())
    }, pause: { _ in })
    automatic.startAutomatically(sessionStart: Date(), canStart: { true }) {}
    for _ in 0..<100 where automatic.isDiscovering || automatic.isRunning { await Task.yield() }
    check(automaticShots == 6 && automatic.status.contains("No speaker names read"),
          "visual: automatic unique window starts bounded capture and explains no names")

    let ambiguous = VisualSpeakerCapture(findWindows: { [zoom, meet] }, snapshot: { _ in
        check(false, "visual: ambiguous discovery must never capture")
        return .init(name: nil, start: Date(), end: Date())
    }, pause: { _ in })
    ambiguous.startAutomatically(sessionStart: Date(), canStart: { true }) {}
    for _ in 0..<100 where ambiguous.isDiscovering { await Task.yield() }
    check(ambiguous.count == 0 && ambiguous.status.contains("Choose a window"),
          "visual: ambiguous automatic discovery asks for manual selection")

    var foundWindows: CheckedContinuation<[SpeakerWindowChoice], Never>?
    let discovery = VisualSpeakerCapture(findWindows: {
        await withCheckedContinuation { foundWindows = $0 }
    }, snapshot: { _ in
        check(false, "visual: stale discovery must never capture")
        return .init(name: nil, start: Date(), end: Date())
    }, pause: { _ in })
    discovery.startAutomatically(sessionStart: Date(), canStart: { true }) {}
    for _ in 0..<100 where foundWindows == nil { await Task.yield() }
    discovery.stop(reset: true)
    foundWindows?.resume(returning: [zoom])
    for _ in 0..<10 { await Task.yield() }
    check(discovery.count == 0 && discovery.status.isEmpty && !discovery.isDiscovering,
          "visual: Stop or new meeting invalidates delayed window discovery")

    var stillAllowed = true
    let revoked = VisualSpeakerCapture(findWindows: {
        stillAllowed = false
        return [zoom]
    }, snapshot: { _ in
        check(false, "visual: revoked discovery must never capture")
        return .init(name: nil, start: Date(), end: Date())
    }, pause: { _ in })
    revoked.startAutomatically(sessionStart: Date(), canStart: { stillAllowed }) {}
    for _ in 0..<100 where revoked.isDiscovering { await Task.yield() }
    check(revoked.count == 0 && !revoked.isRunning,
          "visual: eligibility rechecked after asynchronous discovery")

    var pending: CheckedContinuation<VisualSpeakerCapture.Snapshot, Never>?
    let delayed = VisualSpeakerCapture(snapshot: { _ in
        await withCheckedContinuation { pending = $0 }
    }, pause: { _ in })
    delayed.start(window: window, sessionStart: Date()) { check(false, "visual: stale capture callback") }
    for _ in 0..<100 where pending == nil { await Task.yield() }
    check(pending != nil, "visual: delayed snapshot started")
    delayed.stop(reset: true)
    pending?.resume(returning: .init(name: "Sarah", start: Date(), end: Date()))
    for _ in 0..<10 { await Task.yield() }
    check(delayed.observations.isEmpty && delayed.status.isEmpty && delayed.count == 0,
          "visual: late completion cannot leak into next meeting")

}
