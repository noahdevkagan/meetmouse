import AppKit

@MainActor
func visualSpeakerChecks(scratch: URL) async {
    // ScreenCaptureKit names Zoom "Zoom", not its process name "zoom.us".
    let zoom = SpeakerWindowChoice(id: 1, pid: 1, app: "Zoom", title: "Zoom Meeting", bundleID: "us.zoom.xos")
    let idle = SpeakerWindowChoice(id: 2, pid: 1, app: "Zoom", title: "Zoom Workplace", bundleID: "us.zoom.xos")
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
    check(VisualSpeakerCapture.suggestedWindow(in: [zoom, .init(id: 6, pid: 1, app: "Zoom", title: "Zoom Meeting", bundleID: "us.zoom.xos")]) == nil,
          "visual: identical titles do not disambiguate separate windows")
    // Zoom Workplace 7.x: SCK names the app "Zoom"; the bundle id still says Zoom.
    let zoom7 = SpeakerWindowChoice(id: 7, pid: 4, app: "Zoom", title: "Zoom Meeting", bundleID: "us.zoom.xos")
    let zoom7Home = SpeakerWindowChoice(id: 8, pid: 4, app: "Zoom", title: "Zoom Workplace", bundleID: "us.zoom.xos")
    check(VisualSpeakerCapture.suggestedWindow(in: [zoom7Home, browser, zoom7]) == zoom7,
          "visual: auto-select Zoom 7 meeting window by bundle id")
    check(meet.highlightStyle == .googleMeet && zoom.highlightStyle == .zoom
          && browser.highlightStyle == .zoom && fake.highlightStyle == .zoom,
          "visual: blue-outline adapter is scoped to a recognized Google Meet window")
    let meetApp = SpeakerWindowChoice(id: 9, pid: 5, app: "Google Meet",
                                     title: "Google Meet - Meet - abc-defg-hij",
                                     bundleID: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan")
    check(VisualSpeakerCapture.suggestedWindow(in: [idle, browser, meetApp]) == meetApp
          && meetApp.highlightStyle == .googleMeet && meetApp.platformName == "Google Meet",
          "visual: observed standalone Meet app is detected and uses Meet OCR")
    check(VisualSpeakerCapture.meetingWindows(in: [idle, zoom, browser, meetApp, fake]) == [zoom, meetApp],
          "visual: quick choices contain calls only")
    check(!MeetingWindowHeuristics.isMeetTabWindow(.init(ownerName: "Google Meet", title: "Google Meet",
                                                       ownerBundleID: meetApp.bundleID))
          && !MeetingWindowHeuristics.isMeetTabWindow(.init(ownerName: "Google Meet", title: meetApp.title,
                                                          ownerBundleID: "com.apple.Notes")),
          "visual: standalone Meet home and unrelated bundle are not calls")
    check(MeetingWindowHeuristics.meetingTitle(from: [.init(ownerName: meetApp.app, title: meetApp.title,
                                                          ownerBundleID: meetApp.bundleID)]) == nil,
          "visual: standalone Meet room code is not a human meeting title")
    check(VisualSpeakerCapture.foregroundMeetingWindow(in: [zoom, meetApp], frontmostPID: 5,
                                                      orderedWindowIDs: [9]) == meetApp,
          "visual: explicit switch picks foreground Meet even with Zoom open")
    check(VisualSpeakerCapture.foregroundMeetingWindow(in: [browser, meet], frontmostPID: 2,
                                                      orderedWindowIDs: [3, 4]) == nil,
          "visual: unrelated browser front window cannot select a hidden call")
    check(VisualSpeakerCapture.foregroundMeetingWindow(in: [browser, meet], frontmostPID: 2,
                                                      orderedWindowIDs: [4, 3]) == meet,
          "visual: explicit switch uses window order rather than browser PID alone")
    check(VisualSpeakerCapture.foregroundMeetingWindow(in: [meet], frontmostPID: 2,
                                                      orderedWindowIDs: [99, 4]) == nil
          && VisualSpeakerCapture.foregroundMeetingWindow(in: [meet], frontmostPID: nil,
                                                         orderedWindowIDs: [4]) == nil
          && VisualSpeakerCapture.foregroundMeetingWindow(in: [meet], frontmostPID: 77,
                                                         orderedWindowIDs: [4]) == nil,
          "visual: missing or changed foreground windows do not fall back")

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
    check(VisualSpeakerOCR.cleanName("llya Novak") == "Ilya Novak"
          && VisualSpeakerOCR.cleanName("lvan Petrov") == "Ivan Petrov"
          && VisualSpeakerOCR.cleanName("lan Smith") == "Ian Smith",
          "visual: OCR capital I misread as lowercase l is restored")
    check(VisualSpeakerOCR.cleanName("lisa wong") == "lisa wong"
          && VisualSpeakerOCR.cleanName("léa Roy") == "léa Roy"
          && VisualSpeakerOCR.cleanName("lloyd banks") == "lloyd banks"
          && VisualSpeakerOCR.cleanName("Llya Novak") == "Llya Novak",
          "visual: real lowercase-l names are left alone")

    func fixture(_ rects: [CGRect], names: Bool = true, yellow: Bool = false, radius: CGFloat = 0,
                 border: NSColor? = nil, label: String = "Sarah") -> CGImage {
        let context = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8,
                                bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for rect in rects {
            context.setStrokeColor((border ?? NSColor(calibratedRed: yellow ? 0.95 : 0.2, green: 0.9, blue: 0.15, alpha: 1)).cgColor)
            context.setLineWidth(3)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
            if names {
                (label as NSString).draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 10),
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

    // Use the same "Sarah" glyphs as the Zoom fixture to isolate the adapter:
    // Vision rates some synthetic names below our unchanged confidence floor.
    // Real Vision against Meet-style outlines. Paired tiles both light up
    // even when only one person speaks; multiple outlines must remain a veto.
    let meetBlue = NSColor(calibratedRed: 138 / 255, green: 180 / 255, blue: 248 / 255, alpha: 1)
    let meetLightBlue = NSColor(calibratedRed: 168 / 255, green: 199 / 255, blue: 250 / 255, alpha: 1)
    do {
        for blue in [meetBlue, meetLightBlue] {
            let image = fixture([rect], radius: 16, border: blue)
            check(try VisualSpeakerOCR.activeName(in: image, style: .googleMeet) == "Sarah",
                  "visual: real Vision reads rounded Google Meet blue tile")
            check(try VisualSpeakerOCR.activeName(in: image) == nil,
                  "visual: Zoom adapter rejects a blue frame")
        }
        check(try VisualSpeakerOCR.activeName(in: fixture([rect]), style: .googleMeet) == nil,
              "visual: Meet adapter rejects a green sharing frame")
        check(try VisualSpeakerOCR.activeName(in: fixture([rect], names: false, border: meetBlue),
                                              style: .googleMeet) == nil,
              "visual: Meet without a visible name offers nothing")
        check(try VisualSpeakerOCR.activeName(in: fixture([rect], border: meetBlue, label: "You"),
                                              style: .googleMeet) == nil,
              "visual: Meet self tile never names a remote voice")
        check(try VisualSpeakerOCR.activeName(in: fixture([rect, rect.offsetBy(dx: 380, dy: 0)],
                                                         radius: 16, border: meetBlue),
                                              style: .googleMeet) == nil,
              "visual: Meet paired or simultaneous highlighted tiles are ambiguous")
        check(try VisualSpeakerOCR.activeName(in: fixture([CGRect(x: 4, y: 4, width: 792, height: 492)],
                                                         border: meetBlue), style: .googleMeet) == nil,
              "visual: Meet whole-window frame is not a speaker")
        check(VisualSpeakerOCR.name(in: tile, lines: [.init(text: "You", confidence: 1, rect: line.rect)]) == nil,
              "visual: self label rejected independently of OCR")
    } catch { check(false, "visual: Meet OCR fixture", String(describing: error)) }

    // One-on-one roster: Zoom's screen-share filmstrip has no active-speaker
    // outline. Names come from tiles aligned with the user's own label.
    func label(_ text: String, _ x: Double, _ y: Double, _ h: Double = 0.013,
               _ confidence: Float = 1) -> VisualSpeakerOCR.Line {
        .init(text: text, confidence: confidence, rect: CGRect(x: x, y: y, width: 0.05, height: h))
    }
    let filmstrip = [label("noah kagan", 0.831, 0.669), label("Sam Rivera", 0.833, 0.525),
                     label("Jenkins", 0.40, 0.227), label("Garrett", 0.45, 0.669, 0.02),
                     label("Sam Rivera", 0.017, 0.92, 0.013, 0.3), label("Audio", 0.0, 0.982, 0.0103)]
    check(VisualSpeakerOCR.roster(lines: filmstrip, selfName: "Noah Kagan", aspect: 16 / 9) == ["Sam Rivera"],
          "visual: filmstrip roster keeps only tiles aligned with the user's label")
    check(VisualSpeakerOCR.roster(lines: [label("Noah Kagan", 0.55, 0.9), label("Priya Shah", 0.05, 0.902)],
                                  selfName: "Noah Kagan", aspect: 16 / 9) == ["Priya Shah"],
          "visual: two-tile gallery row roster")
    check(VisualSpeakerOCR.roster(lines: filmstrip + [label("the reason", 0.5, 0.666)],
                                  selfName: "Noah Kagan", aspect: 16 / 9) == ["Sam Rivera"],
          "visual: text level with the user's filmstrip tile ignored")
    check(VisualSpeakerOCR.roster(lines: filmstrip, selfName: "Home Mac", aspect: 16 / 9) == nil,
          "visual: no roster without the user's own label")
    check(VisualSpeakerOCR.roster(lines: filmstrip + [label("Noah Kagan", 0.2, 0.3)],
                                  selfName: "Noah Kagan", aspect: 16 / 9) == nil,
          "visual: ambiguous self label gives no roster")
    check(VisualSpeakerOCR.roster(lines: [label("noah kagan", 0.831, 0.669)],
                                  selfName: "Noah Kagan", aspect: 16 / 9) == [],
          "visual: alone on screen is an empty roster")
    check(VisualSpeakerOCR.roster(lines: [label("noah kagan", 0.831, 0.669), label("% Sam Rivera", 0.833, 0.525)],
                                  selfName: "Noah Kagan", aspect: 16 / 9) == ["Sam Rivera"],
          "visual: muted-mic icon prefix stripped")
    check(VisualSpeakerOCR.isSelf("noah kagan", "Noah Kagan") && VisualSpeakerOCR.isSelf("Noah", "Noah Kagan")
          && VisualSpeakerOCR.isSelf("Noah K", "Noah Kagan") && VisualSpeakerOCR.isSelf("Noah Kagan", "noah") && VisualSpeakerOCR.isSelf("noah kagan", "Noah K")
          && !VisualSpeakerOCR.isSelf("Noah Smith", "Noah Kagan") && !VisualSpeakerOCR.isSelf("Noam", "Noah Kagan"),
          "visual: self-name matching tolerates case and short forms")

    let one: Set<String> = ["Them 1"]
    let seen = [VisualRosterObservation(names: ["Sam Rivera"], time: 5),
                VisualRosterObservation(names: ["sam rivera"], time: 20)]
    check(VisualSpeakerEvidence.rosterMatch(seen, remoteLabels: one).map { "\($0.label)=\($0.name)" } == "Them 1=Sam Rivera",
          "visual: repeated one-on-one roster names the only remote voice")
    check(VisualSpeakerEvidence.rosterMatch([seen[0]], remoteLabels: one) == nil,
          "visual: one roster snapshot is not enough")
    check(VisualSpeakerEvidence.rosterMatch([seen[0], .init(names: ["Sam Rivera"], time: 9)], remoteLabels: one) == nil,
          "visual: roster snapshots must be spread out")
    check(VisualSpeakerEvidence.rosterMatch(seen, remoteLabels: ["Them 1", "Them 2"]) == nil,
          "visual: second remote voice vetoes roster")
    check(VisualSpeakerEvidence.rosterMatch(seen + [.init(names: ["Sam Rivera", "Priya"], time: 35)], remoteLabels: one) == nil,
          "visual: second visible guest vetoes roster")
    check(VisualSpeakerEvidence.rosterMatch(seen + [.init(names: ["Priya"], time: 35)], remoteLabels: one) == nil,
          "visual: conflicting roster names veto")
    check(VisualSpeakerEvidence.rosterMatch(seen + [.init(names: [], time: 35)], remoteLabels: one)?.name == "Sam Rivera",
          "visual: unreadable snapshots do not veto")
    check(VisualSpeakerEvidence.rosterMatch(seen, remoteLabels: ["Them"]) == nil
          && VisualSpeakerEvidence.rosterMatch(seen, remoteLabels: ["Sam Rivera"]) == nil,
          "visual: roster only names an unnamed diarized remote voice")

    // Real Vision OCR over a synthetic Zoom screen-share window: a shared
    // page with a dark bookmarks bar (same text size) must not count.
    func shareFixture() -> CGImage {
        let w = 1600, h = 900
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        func fill(_ r: CGRect, _ c: NSColor) { c.setFill(); NSBezierPath(rect: r).fill() }
        func text(_ s: String, _ p: CGPoint, _ c: NSColor) {
            (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: c])
        }
        fill(CGRect(x: 0, y: 0, width: w, height: h), NSColor(white: 0.1, alpha: 1))
        fill(CGRect(x: 20, y: 80, width: 1280, height: 760), .white)
        fill(CGRect(x: 20, y: 80, width: 1280, height: 40), NSColor(white: 0.15, alpha: 1))
        text("Jenkins", CGPoint(x: 60, y: 92), .white)
        text("Garrett Moss", CGPoint(x: 200, y: 92), .white)
        text("Sarah Lee", CGPoint(x: 60, y: 300), .black)
        text("Garrett Moss", CGPoint(x: 600, y: 467), .black) // level with the user's label
        for (i, name) in ["Sam Rivera", "noah kagan"].enumerated() {
            let tile = CGRect(x: 1330, y: 330 + i * 160, width: 250, height: 158)
            NSColor(calibratedRed: 0.55, green: 0.5, blue: 0.45, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8).fill()
            NSColor(white: 0.12, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: CGRect(x: tile.minX + 4, y: tile.maxY - 26, width: 90, height: 22),
                         xRadius: 6, yRadius: 6).fill()
            text(name, CGPoint(x: tile.minX + 10, y: tile.maxY - 23), .white)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
    do {
        let image = shareFixture()
        let roster = try VisualSpeakerOCR.remoteRoster(in: image, selfName: "Noah Kagan")
        // macOS 14's Vision (CI's macos-14 runner) returns no text for this
        // small synthetic tile label; macOS 15+ reads it. Skip rather than
        // block releases on the older OCR model.
        if #available(macOS 15, *) {
            check(roster == ["Sam Rivera"], "visual: real Vision OCR reads screen-share filmstrip roster", "\(roster ?? [])")
        } else {
            print("session visual: real Vision OCR reads screen-share filmstrip roster: SKIP (macOS 14 OCR)")
        }
        check(try VisualSpeakerOCR.activeName(in: image) == nil, "visual: filmstrip without outline names no speaker")
        check(try VisualSpeakerOCR.remoteRoster(in: image, selfName: "Home Mac") == nil,
              "visual: filmstrip roster needs the user's name")
    } catch { check(false, "visual: roster OCR fixture", String(describing: error)) }

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
    check(ambiguous.count == 0 && ambiguous.status.contains("Choose your call"),
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

    // Integrate real Vision, automatic discovery/capture, the real live VM,
    // late diarization, confirmation and saved output. Only the screenshot
    // source, elapsed time and audio hardware are fixtures.
    UserDefaults.standard.set(true, forKey: VisualSpeakerCapture.automaticDefaultsKey)
    defer { UserDefaults.standard.removeObject(forKey: VisualSpeakerCapture.automaticDefaultsKey) }
    for choice in [zoom, meet] {
        let platform = choice.highlightStyle == .googleMeet ? "Meet" : "Zoom"
        let image = fixture([rect], radius: 16,
                            border: choice.highlightStyle == .googleMeet ? meetBlue : nil)
        var shots = 0
        let screenshots = VisualSpeakerCapture(findWindows: { [choice] }, snapshot: { selected in
            let at = (AudioCaptureManager.last?.startTime ?? Date())
                .addingTimeInterval(10 + Double(shots) * 15)
            shots += 1
            let name = try VisualSpeakerOCR.activeName(in: image, style: selected.highlightStyle)
            return .init(name: name, start: at, end: at.addingTimeInterval(0.1))
        }, pause: { _ in })
        let vm = LiveSessionViewModel(visualSpeakerCapture: screenshots)
        vm.startLive(context: PreCallContext())
        for _ in 0..<300 where screenshots.count < 6 || screenshots.isRunning {
            await Task.yield()
        }
        guard let audio = AudioCaptureManager.last else {
            check(false, "visual pipeline \(platform): audio callbacks wired")
            vm.stopLive()
            continue
        }
        check(shots == 6 && screenshots.observations.count == 6,
              "visual pipeline \(platform): automatic snapshots reach real OCR")
        check(!vm.speakerNameSuggestions.contains { $0.kind == .visualName },
              "visual pipeline \(platform): readable names wait for voice evidence")

        let words = "The \(platform) verification checks the speaker name from image to saved transcript."
        audio.onUtterance?(Utterance(t: 6, speaker: "Them", text: words, endT: 100))
        try? await Task.sleep(for: .milliseconds(50))
        let solo = [SpeakerSegment(speaker: "Them 1", start: 5, end: 105)]
        audio.onSpeakerSegments?(.system, solo)
        var suggestion = vm.speakerNameSuggestions.first { $0.kind == .visualName }
        check(suggestion?.label == "Them 1" && suggestion?.name == "Sarah",
              "visual pipeline \(platform): late voice evidence produces correct suggestion")
        check(vm.utterances.first?.speaker == "Them 1",
              "visual pipeline \(platform): suggestion awaits confirmation")

        audio.onSpeakerSegments?(.system, solo + [.init(speaker: "Them 2", start: 5, end: 105)])
        check(!vm.speakerNameSuggestions.contains { $0.kind == .visualName },
              "visual pipeline \(platform): revised overlapping voices withdraw suggestion")
        audio.onSpeakerSegments?(.system, solo)
        suggestion = vm.speakerNameSuggestions.first { $0.kind == .visualName }
        if let suggestion { vm.confirmNameSuggestion(suggestion) }
        check(vm.turns.contains { $0.speaker == "Sarah" }
              && audio.renames.contains { $0 == ("Them 1", "Sarah") },
              "visual pipeline \(platform): confirmation updates transcript and capture")
        audio.onSpeakerSegments?(.system, solo)
        check(vm.utterances.first?.speaker == "Sarah",
              "visual pipeline \(platform): late segments preserve confirmed name")

        vm.stopLive()
        let files = (try? FileManager.default.contentsOfDirectory(at: scratch,
                                                                  includingPropertiesForKeys: nil)) ?? []
        let saved = files.filter { $0.pathExtension == "md" }.compactMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }.first { $0.contains(words) }
        check(saved?.contains("Sarah: \(words)") == true,
              "visual pipeline \(platform): confirmed name persists after Stop")
        vm.deleteSession()
    }
}
