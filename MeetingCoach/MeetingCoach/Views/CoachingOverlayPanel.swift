import SwiftUI
import AppKit

/// A floating panel that shows coaching nudges on top of all windows (including Zoom).
/// Uses sharingType = .none so it's invisible during screen shares.
final class CoachingOverlayPanel: NSPanel {

    /// Double-click opens the main window. Handled here rather than with a
    /// SwiftUI tap gesture, which would claim mouse-down and stop
    /// isMovableByWindowBackground from dragging the bubble.
    var onDoubleClick: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        super.sendEvent(event)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 156, height: 56),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .none  // invisible in screen shares

        // A dragged position is the user telling us where the overlay
        // belongs — restore it forever after (Noah moved it repeatedly and
        // every nudge snapped it back to the main screen's top-right).
        if let saved = Self.savedUserFrame(),
           let visible = NSScreen.screens.first(where: { $0.visibleFrame.intersects(saved) })?.visibleFrame {
            // A saved wide overlay may only partly intersect the display;
            // clamp the smaller replacement so it cannot land off-screen.
            setFrameOrigin(NSPoint(
                x: min(max(saved.maxX - frame.width, visible.minX), visible.maxX - frame.width),
                y: min(max(saved.maxY - frame.height, visible.minY), visible.maxY - frame.height)))
        } else {
            positionAtTopRight(of: NSScreen.main)
        }

        // A display being plugged/unplugged can strand the panel on a
        // screen that no longer exists — re-clamp onto a live one.
        // (Selector-based: this notification posts on the main thread.)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenConfigChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didMove),
            name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didResize),
            name: NSWindow.didResizeNotification, object: self)
    }

    private(set) var placement: TalkBubblePlacement = .floating

    func setPlacement(_ placement: TalkBubblePlacement) {
        guard self.placement != placement else { return }
        self.placement = placement
        isMovableByWindowBackground = placement == .floating
        repositionProgrammatically {
            if placement == .rightEdge {
                positionAtRightEdge(of: screen ?? NSScreen.main)
            } else if let saved = Self.savedUserFrame(),
                      let target = NSScreen.screens.first(where: { $0.visibleFrame.intersects(saved) }) {
                var restored = frame
                restored.origin = NSPoint(x: saved.maxX - frame.width, y: saved.maxY - frame.height)
                setFrame(clamped(restored, to: target.visibleFrame), display: true)
            } else {
                positionAtTopRight(of: screen ?? NSScreen.main)
            }
        }
    }

    private func clamped(_ rect: NSRect, to visible: NSRect) -> NSRect {
        var result = rect
        result.origin.x = max(visible.minX, min(rect.minX, visible.maxX - rect.width))
        result.origin.y = max(visible.minY, min(rect.minY, visible.maxY - rect.height))
        return result
    }

    private func positionAtRightEdge(of target: NSScreen?) {
        guard let target else { return }
        setFrameOrigin(NSPoint(x: target.frame.maxX - frame.width,
                               y: target.visibleFrame.midY - frame.height / 2))
    }

    // Docked mode deliberately reaches the physical display edge, including
    // when the macOS Dock reduces visibleFrame on the right.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        placement == .rightEdge ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    @objc private func screenConfigChanged() {
        repositionProgrammatically {
            let target = screen ?? NSScreen.main
            if placement == .rightEdge {
                positionAtRightEdge(of: target)
            } else if let target {
                setFrame(clamped(frame, to: target.visibleFrame), display: true)
            }
        }
    }

    // MARK: - User-position memory

    private static let userFrameKey = "coachOverlayUserFrame"
    private var inProgrammaticMove = false

    /// Whether the user has ever dragged the panel (persisted).
    var hasUserPosition: Bool {
        UserDefaults.standard.string(forKey: Self.userFrameKey) != nil
    }

    @objc private func didResize() {
        // NSHostingView can resize the native window after fitContent or when
        // installed, preserving its left edge. Re-anchor that final size too.
        guard !inProgrammaticMove, placement == .rightEdge else { return }
        repositionProgrammatically { positionAtRightEdge(of: screen ?? NSScreen.main) }
    }

    @objc private func didMove() {
        guard !inProgrammaticMove, placement == .floating else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.userFrameKey)
    }

    private func repositionProgrammatically(_ body: () -> Void) {
        inProgrammaticMove = true
        body()
        inProgrammaticMove = false
    }

    /// Keep the top-right corner anchored when a nudge expands the bubble.
    /// Resizing is not a user drag and must not overwrite their saved position.
    func fitContent(_ size: CGSize) {
        guard frame.size != size || placement == .rightEdge else { return }
        repositionProgrammatically {
            let target = screen ?? NSScreen.main
            var next = NSRect(x: frame.maxX - size.width, y: frame.maxY - size.height,
                              width: size.width, height: size.height)
            if placement == .rightEdge, let target {
                next.origin = NSPoint(x: target.frame.maxX - size.width, y: target.visibleFrame.midY - size.height / 2)
            } else if let visible = target?.visibleFrame {
                next.origin.x = min(max(next.minX, visible.minX), visible.maxX - size.width)
                next.origin.y = min(max(next.minY, visible.minY), visible.maxY - size.height)
            }
            setFrame(next, display: true)
        }
    }

    private static func savedUserFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: userFrameKey) else { return nil }
        let rect = NSRectFromString(s)
        return rect.isEmpty ? nil : rect
    }

    // Allow the panel to become key for dragging but not steal focus
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Move to the screen holding the frontmost app's window — the one the
    /// user is actually looking at (a fullscreen call on a second display).
    /// A user who has ever dragged the panel has picked its home — never
    /// override that (follow-the-action only serves the default position).
    func repositionToActiveScreen() {
        guard placement == .rightEdge || !hasUserPosition else { return }
        guard let target = Self.screenOfFrontmostWindow() ?? NSScreen.main else { return }
        if placement == .floating, isVisible, screen == target { return }
        repositionProgrammatically {
            if placement == .rightEdge { positionAtRightEdge(of: target) }
            else { positionAtTopRight(of: target) }
        }
    }

    private func positionAtTopRight(of screen: NSScreen?) {
        guard let screen else { return }
        let x = screen.visibleFrame.maxX - frame.width - 20
        let y = screen.visibleFrame.maxY - frame.height - 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// The screen containing the frontmost app's biggest on-screen window.
    /// Window bounds (unlike titles) need no Screen Recording permission.
    private static func screenOfFrontmostWindow() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // CG coords: origin top-left of the primary display, y down.
        // Cocoa: origin bottom-left, y up. Convert through primary height.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == app.processIdentifier,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 200, bounds.height > 150   // skip status items / tooltips
            else { continue }
            let center = NSPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        return nil
    }
}

/// A compact ambient bubble that expands only for coaching or actionable notices.
struct CoachingOverlayView: View {
    var liveSession: LiveSessionViewModel
    var settings: SettingsViewModel
    let onClose: () -> Void
    var onSizeChange: (CGSize) -> Void = { _ in }
    var onOpenApp: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool {
        activeNudge != nil || liveSession.micWarning != nil
            || liveSession.memoryPressureTipVisible || liveSession.basicModeNotice != nil
    }

    private var sessionShare: Double? {
        guard !liveSession.micOnly, let share = liveSession.talkStats.sessionShare else { return nil }
        return min(1, max(0, share))
    }

    private var shareDescription: String {
        guard let share = sessionShare else { return "Talk share unavailable" }
        return "Estimated talk share: you \(Int((share * 100).rounded())) percent, others \(Int(((1 - share) * 100).rounded())) percent"
    }

    private var activeNudge: Nudge? { liveSession.activeNudge }

    var body: some View {
        Group {
            if expanded {
                expandedContent
            } else {
                compactContent
            }
        }
        .fixedSize()
        .padding(EdgeInsets(top: 6, leading: 6, bottom: 6,
                            trailing: settings.talkBubblePlacement == .rightEdge ? 0 : 6))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { onSizeChange(geometry.size) }
                    .onChange(of: geometry.size) { _, size in onSizeChange(size) }
            }
        }
        .contextMenu {
            Button("Hide overlay", action: onClose)
        }
        .accessibilityAction(named: "Hide overlay", onClose)
    }

    private var compactContent: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let speaking = liveSession.isLive && context.date.timeIntervalSince(liveSession.overlaySpeechAt) < 2.5
            let color: Color = !speaking || liveSession.micOnly || liveSession.overlaySpeaker == "Meeting"
                ? .secondary : liveSession.overlaySpeaker == "You" ? Dorado.dollar : .blue
            let activity = !speaking ? "Listening" : liveSession.micOnly || liveSession.overlaySpeaker == "Meeting"
                ? "Speech detected" : liveSession.overlaySpeaker == "You" ? "You speaking" : "Others speaking"
            let vertical = settings.talkBubbleLayout == .vertical
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 9)) : AnyLayout(HStackLayout(spacing: 11))
            layout {
                // Only the bars redraw at 30 Hz, and only while someone is speaking.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !speaking || reduceMotion)) { bars in
                    HStack(spacing: 3) {
                        ForEach(0..<5) { index in
                            Capsule()
                                .fill(color)
                                .frame(width: 3, height: barHeight(index, speaking: speaking, at: bars.date))
                        }
                    }
                }
                .frame(width: 27, height: 20)
                .accessibilityHidden(true)
                if settings.showOverlayClock {
                    Text(liveSession.elapsedFormatted)
                        .font(.system(size: vertical ? 10 : 13, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(vertical ? 0.65 : 0.8)
                }
            }
            .padding(.horizontal, vertical ? 6 : 14)
            .frame(width: vertical ? 44 : 144, height: vertical ? 84 : 44)
            .background(Dorado.surface)
            .overlay(alignment: .leading) {
                shareEdge(sessionShare, color: Dorado.dollar)
            }
            .overlay(alignment: .trailing) {
                shareEdge(sessionShare.map { 1 - $0 }, color: .blue)
            }
            .clipShape(bubbleShape)
            .overlay {
                bubbleShape
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Meeting activity")
            .accessibilityValue("\(activity). \(liveSession.elapsedFormatted) elapsed. \(shareDescription)")
            .accessibilityAction(named: "Open MeetMouse", onOpenApp)
        }
        .help("\(shareDescription). Double-click to open MeetMouse; \(settings.talkBubblePlacement == .floating ? "drag to move; " : "")right-click to hide.")
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private func shareEdge(_ share: Double?, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                color.opacity(0.12)
                color.frame(height: geometry.size.height * (share ?? 0))
            }
        }
        .frame(width: settings.talkBubbleLayout == .vertical ? 4 : 7)
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: share)
    }

    private func barHeight(_ index: Int, speaking: Bool, at date: Date) -> CGFloat {
        guard speaking else { return 4 }
        let heights: [CGFloat] = [8, 15, 20, 12, 7]
        guard !reduceMotion else { return heights[index] }
        let phase = date.timeIntervalSinceReferenceDate * 14 + Double(index) * 1.7
        return 5 + (heights[index] - 5) * CGFloat((sin(phase) + 1) / 2)
    }

    private var expandedContent: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(liveSession.isLive ? Dorado.dollar : Color.gray)
                    .frame(width: 6, height: 6)

                if let nudge = activeNudge {
                    // Urgency dot (green = reinforcement, not a correction)
                    Circle()
                        .fill(nudgeColor(nudge))
                        .frame(width: 8, height: 8)

                    // Let short coaching text wrap when feedback controls need room.
                    Text(nudge.text)
                        .font(.callout.bold())
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    // Feedback buttons
                    HStack(spacing: 4) {
                        feedbackButton(nudge: nudge, feedback: .useful,
                                       icon: "hand.thumbsup.fill", color: Dorado.dollar)
                        feedbackButton(nudge: nudge, feedback: .annoying,
                                       icon: "minus.circle.fill", color: .gray)
                        feedbackButton(nudge: nudge, feedback: .wrong,
                                       icon: "xmark.circle.fill", color: .red)
                    }
                } else if liveSession.memoryPressureTipVisible {
                    // The overlay is where the user actually looks during a
                    // call — the pressure tip must be actionable here, not
                    // just in a main window buried behind Zoom. The main
                    // window carries the full copy.
                    Text("🐢")
                        .font(.caption)
                    Text("Memory pressure — turn off AI?")
                        .font(.caption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Turn off") {
                        liveSession.shedSessionModel(settings: settings)
                    }
                    .font(.caption2)
                    .controlSize(.small)
                    Button("Keep") {
                        liveSession.declineMemoryPressureTip()
                    }
                    .font(.caption2)
                    .controlSize(.small)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else if liveSession.micWarning != nil {
                    // The bubble is what the user watches during a call; a
                    // dead mic must show here, not only in the main window
                    // (which carries the full explanation and fixes). After
                    // the memory tip: that one is short-lived and urgent.
                    Image(systemName: "mic.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text("Can't hear your mic")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Fix") { onOpenApp() }
                        .font(.caption2)
                        .controlSize(.small)
                    Button("Hide") { liveSession.dismissMicWarning() }
                        .font(.caption2)
                        .controlSize(.small)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else if let notice = liveSession.basicModeNotice {
                    // Degraded coaching would otherwise look identical to a
                    // meeting with nothing to say — name it where the user is
                    // actually looking. The main window carries the fix.
                    Image(systemName: "bolt.slash.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Basic mode — \(notice.cause)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if settings.showOverlayClock {
                        Text(liveSession.elapsedFormatted)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                // Close
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Talk-share meter — stays visible under active nudges. The
            // trailing window is what the user can still change; fall back
            // to the session share early on.
            if liveSession.isLive,
               let share = liveSession.talkStats.recentShare ?? liveSession.talkStats.sessionShare {
                TalkMeterBar(share: share)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 300)
        .frame(minHeight: 36)
        // Tint wash under the material while a nudge shows — positives get
        // an unmistakable green; corrections a lighter cue.
        .background(activeNudge.map { nudgeColor($0).opacity($0.type.isPositive ? 0.22 : 0.12) } ?? Color.clear)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(activeNudge.map { nudgeColor($0).opacity(0.55) } ?? Color.primary.opacity(0.08),
                        lineWidth: activeNudge == nil ? 1 : 1.5)
        )
    }

    private func feedbackButton(nudge: Nudge, feedback: NudgeFeedback, icon: String, color: Color) -> some View {
        Button {
            liveSession.recordFeedback(nudgeId: nudge.id, feedback: feedback)
        } label: {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private func nudgeColor(_ nudge: Nudge) -> Color {
        if nudge.type.isPositive { return Dorado.dollar }
        switch nudge.urgency {
        case .low: return .gray
        case .med: return .blue
        case .high: return .orange
        }
    }
}

/// Thin two-tone you/them bar with a percentage label. Your share is green,
/// matching the compact bubble's You edge. Orange past 65% — the point where
/// coaching notes consistently call the floor hogged.
struct TalkMeterBar: View {
    let share: Double
    var warnAt: Double = TalkStats.warnShare

    var body: some View {
        HStack(spacing: 6) {
            Text("You \(Int(share * 100))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(share >= warnAt ? Color.orange : Color.secondary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(share >= warnAt ? Color.orange : Dorado.dollar)
                        .frame(width: max(3, geo.size.width * share))
                }
            }
            .frame(height: 4)
        }
        .animation(.easeOut(duration: 0.4), value: share)
    }
}
