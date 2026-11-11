import Foundation

// EchoFilter behavior checks (pure logic, no audio). The filter is what
// keeps the far side's voice — leaking speakers → mic — out of the "You"
// channel, sentence by sentence. The original sentence-level filter was tuned
// on a 2026-07-14 replay (3,771 leaked words reduced to 481). These checks
// preserve its echo fixtures while guarding against genuine replies being lost.

var fail = false
func check(_ name: String, _ ok: Bool) {
    print("echo \(name): \(ok ? "PASS" : "FAIL")")
    if !ok { fail = true }
}

let base = Date(timeIntervalSinceReferenceDate: 1_000)
func at(_ t: TimeInterval) -> Date { base.addingTimeInterval(t) }

// 1. A mic chunk mixing an echoed sentence with genuine speech keeps only
//    the genuine part, and reports the kept fraction for span scaling.
do {
    let f = EchoFilter()
    var now = at(0); f.clock = { now }
    f.recordFarText("My husband's nerdy about tracking water levels and yard health.")
    now = at(4)
    let r = f.filter("My husband is nerdy about tracking water levels and yard health. Is he excited about the free water?",
                     since: at(-3))
    check("strips echoed sentence", r?.text == "Is he excited about the free water?")
    check("reports kept fraction", r.map { $0.keptFraction > 0 && $0.keptFraction < 1 } ?? false)
}

// 2. A chunk that is entirely echo is dropped outright.
do {
    let f = EchoFilter()
    var now = at(0); f.clock = { now }
    f.recordFarText("we just got an inch in forty six minutes")
    now = at(2)
    check("drops all-echo chunk",
          f.filter("We just got an inch in 46 minutes.", since: at(-3)) == nil)
}

// 3. Genuine speech with no far-side overlap passes through untouched.
do {
    let f = EchoFilter()
    f.recordFarText("the quarterly numbers look strong across every region")
    let r = f.filter("I want to talk about hiring for the sales team.", since: at(-3))
    check("keeps genuine speech", r?.text == "I want to talk about hiring for the sales team." && r?.keptFraction == 1.0)
}

// 4. Short backchannels ("Okay.", "Yeah.") are never classified as echo,
//    even when the far side just said the same words.
do {
    let f = EchoFilter()
    f.recordFarText("okay yeah that sounds right")
    let r = f.filter("Okay. Yeah.", since: at(-3))
    check("keeps short backchannels", r?.text == "Okay. Yeah.")
}

// 5. The pool is time-windowed: far-side words heard before `since` can't
//    be the source of this chunk's echo.
do {
    let f = EchoFilter()
    var now = at(0); f.clock = { now }
    f.recordFarText("my husband is nerdy about tracking water levels")
    now = at(60)
    let r = f.filter("My husband is nerdy about tracking water levels.", since: at(30))
    check("ignores stale far words", r?.keptFraction == 1.0)
}

// 6. Growing partials supply complete ordered phrases before far-side commit.
do {
    let f = EchoFilter()
    var now = at(0); f.clock = { now }
    f.recordFarPartial("we got an")
    now = at(1)
    f.recordFarPartial("we got an inch this morning")
    now = at(3)
    check("matches growing partial phrase",
          f.filter("We got an inch this morning.", since: at(-3)) == nil)
}

// Shared vocabulary is not enough: this real-shaped coaching reply has
// opposite intent to the question and used to be reduced to just "Non.".
do {
    let f = EchoFilter()
    f.clock = { at(0) }
    f.recordFarText("Vous ne voulez pas rester dans cette équipe ? Vous préférez changer de travail ?")
    let reply = "Non. Je veux rester dans cette équipe."
    let r = f.filter(reply, since: at(-3))
    check("keeps French coaching reply", r?.text == reply && r?.keptFraction == 1)
}

do {
    let f = EchoFilter()
    f.clock = { at(0) }
    f.recordFarText("Hiring is difficult. We should discuss budgets. Tomorrow is fine.")
    let reply = "Tomorrow we should discuss hiring."
    check("does not pool unrelated sentences", f.filter(reply, since: at(-3))?.text == reply)
}

do {
    let f = EchoFilter()
    f.clock = { at(0) }
    f.recordFarText("Alice helps Bob while Carol helps David.")
    let reply = "David helps Carol while Bob helps Alice."
    check("respects word order", f.filter(reply, since: at(-3))?.text == reply)
    let repeated = "Alice Alice Alice Alice Alice."
    check("counts repeated words separately", f.filter(repeated, since: at(-3))?.text == repeated)
}

// Revised partials must remain separate hypotheses, never one invented phrase.
do {
    let f = EchoFilter()
    f.clock = { at(0) }
    f.recordFarPartial("red orange yellow")
    f.recordFarPartial("green blue purple")
    let reply = "red orange yellow green blue purple"
    check("does not join partial revisions", f.filter(reply, since: at(-3))?.text == reply)
    check("catches revised partial echo", f.filter("green blue purple", since: at(-3)) == nil)
}

// Echo may occupy only part of a longer far-side utterance, with ASR errors.
do {
    let f = EchoFilter()
    f.clock = { at(0) }
    f.recordFarText("Well I think the quarterly numbers look strong across every region this year.")
    check("catches embedded echo with ASR substitution",
          f.filter("The quarterly numbers look good across every region.", since: at(-3)) == nil)
    let french = EchoFilter()
    french.clock = { at(0) }
    french.recordFarPartial("Je veux rester dans cette équipe.")
    check("catches French echo",
          french.filter("Je veux rester dans cette équipe.", since: at(-3)) == nil)
}

do {
    let f = EchoFilter()
    var now = at(0); f.clock = { now }
    f.recordFarPartial("We should hire more people")
    now = at(10)
    f.recordFarPartial("We should hire more people after the launch")
    check("growing partial does not refresh old words",
          f.filter("We should hire more people", since: at(5))?.keptFraction == 1)
    check("growing partial retains fresh suffix",
          f.filter("after the launch", since: at(5)) == nil)
    now = at(60)
    check("expires evidence even without new far speech",
          f.filter("after the launch", since: at(-3))?.keptFraction == 1)
    f.recordFarPartial("")
    f.recordFarPartial("after the launch")
    check("empty partial resets next utterance",
          f.filter("after the launch", since: at(59)) == nil)
}

// Degraded echo often loses the far side's punctuation, so one mic sentence
// can span two far sentences. It must still be caught.
do {
    let f = EchoFilter()
    f.clock = { at(0) }
    f.recordFarText("We got an inch this morning. The roads were closed until noon.")
    check("catches echo across far sentence boundary",
          f.filter("We got an inch this morning the roads were closed until noon.", since: at(-3)) == nil)
    let p = EchoFilter()
    p.clock = { at(0) }
    p.recordFarPartial("So the plan is simple. We ship on Friday and review Monday.")
    check("catches partial echo across far sentence boundary",
          p.filter("So the plan is simple we ship on Friday.", since: at(-3)) == nil)
}

do {
    let f = EchoFilter()
    f.clock = { at(0) }
    f.recordFarText("You agree with me.")
    let reply = "I agree with you."
    check("keeps changed short reply", f.filter(reply, since: at(-3))?.text == reply)
}

// ---- ShortEchoGate: 1-2 word bleed duplicates on built-in speakers ----
// A replay of the capture path: events arrive in the order the pipelines
// deliver them (system voice, mic commit, Them partial, Them commit, route
// change, Stop) and go through the same gate calls AudioCaptureManager makes.
// Releases run as "main-thread blocks" (`mainQueue`), as in the app: a block
// queued before Stop but not yet run when Stop executes models the race
// where the hold timer fires while stopLive is on main. `transcript` is what
// reaches the session before the save; `late` is what arrives after it.
final class CaptureSim {
    let gate = ShortEchoGate()
    var onSpeakers: Bool
    var now: TimeInterval = 0
    var transcript: [Utterance] = []
    var late: [Utterance] = []
    var stopped = false
    /// When each You line reached the session (its delay = arrival - endT).
    var arrivedAt: [String: TimeInterval] = [:]
    private var mainQueue: [TimeInterval] = []

    init(onSpeakers: Bool = true) { self.onSpeakers = onSpeakers }

    /// Far side voiced over [from, to] (system buffers above the voice floor).
    func farAudio(_ from: TimeInterval, _ to: TimeInterval) { gate.noteFarVoiced(from: from, to: to) }

    @discardableResult
    func mic(_ t: TimeInterval, _ end: TimeInterval, _ text: String, at: TimeInterval) -> ShortEchoGate.Decision {
        advance(to: at)
        let u = Utterance(t: t, speaker: "You", text: text, endT: end)
        let d = gate.submit(u, onSpeakers: onSpeakers, now: now)
        switch d {
        case .drop: break
        case .hold: mainQueue.append(now + ShortEchoGate.holdSeconds + 0.05)
        case .deliver: deliver(u)
        }
        return d
    }
    func farPartial(_ text: String, at: TimeInterval) {
        advance(to: at)
        _ = gate.recordFarPartial(text, now: now)
        if gate.hasReleasable { mainQueue.append(now); runMain() }
    }
    func far(_ t: TimeInterval, _ end: TimeInterval, _ text: String, at: TimeInterval) {
        advance(to: at)
        _ = gate.recordFarPartial("", now: now)   // commit clears the partial
        _ = gate.recordFar(Utterance(t: t, speaker: "Them", text: text, endT: end), now: now)
        if gate.hasReleasable { mainQueue.append(now); runMain() }
        deliver(Utterance(t: t, speaker: "Them", text: text, endT: end))
    }
    /// Route leaves the built-in speakers, or system audio degrades to
    /// mic-only: both turn the gate off and release what it holds.
    func gateOff(at: TimeInterval) {
        advance(to: at)
        onSpeakers = false
        gate.releaseAll()
        mainQueue.append(now); runMain()
    }
    /// Advance the clock; main blocks due by then run unless `holdMain`.
    func advance(to t: TimeInterval, holdMain: Bool = false) {
        now = max(now, t)
        if !holdMain { runMain() }
    }
    private func runMain() {
        mainQueue.sort()
        while let first = mainQueue.first, first <= now {
            mainQueue.removeFirst()
            for u in gate.release(now: first) { deliver(u, at: first) }
        }
    }
    private func deliver(_ u: Utterance, at: TimeInterval? = nil) {
        if stopped { late.append(u) } else { transcript.append(u) }
        if u.isYou { arrivedAt[u.text] = at ?? now }
    }
    /// stopLive: close the gate (drain) on main, then save. Main blocks
    /// already due but not yet run execute after it.
    func stop() {
        transcript += gate.close()
        stopped = true
        runMain()
    }
    var you: [String] { transcript.filter(\.isYou).map(\.text) }
    var them: [String] { transcript.filter { !$0.isYou }.map(\.text) }
}

// Guest says "Okay." over the speakers at 10.0-10.5; it bleeds into the mic.
// Mic commits ~0.9 s of silence later, the system channel ~2 s later.
do {  // mic first (the field case)
    let s = CaptureSim()
    s.farAudio(10.0, 10.5)
    s.mic(10.1, 10.4, "Okay.", at: 11.4)
    s.far(10.0, 10.5, "Okay.", at: 12.6)
    s.advance(to: 20); s.stop()
    check("short dup dropped, mic first", s.you.isEmpty && s.them == ["Okay."])
}
do {  // mic first, twin proven by a Them partial before the Them commit
    let s = CaptureSim()
    s.farAudio(10.0, 10.5)
    s.farPartial("Okay", at: 11.0)
    s.mic(10.1, 10.4, "Okay.", at: 11.4)
    check("dropped at once on partial evidence", s.gate.heldCount == 0 && s.you.isEmpty)
    // Guest keeps talking: the commit only comes much later.
    s.farAudio(11.0, 18.0)
    s.far(10.0, 18.0, "Okay. So the plan for next week is simple.", at: 20.5)
    s.advance(to: 30); s.stop()
    check("short dup dropped via partial, late commit", s.you.isEmpty && s.them.count == 1)
}
do {  // mic first, guest continues: twin only in partials, no commit within the hold
    let s = CaptureSim()
    s.farAudio(10.0, 12.0)
    s.mic(10.1, 10.4, "Okay.", at: 11.4)
    s.farPartial("Okay. So the", at: 12.0)
    s.advance(to: 20)
    check("held line dropped by later partial", s.you.isEmpty)
}
do {  // system first
    let s = CaptureSim()
    s.far(10.0, 10.5, "Okay.", at: 11.2)
    s.mic(10.1, 10.4, "Okay.", at: 11.6)
    s.advance(to: 20); s.stop()
    check("short dup dropped, system first", s.you.isEmpty && s.them == ["Okay."])
}
do {  // two-word duplicate
    let s = CaptureSim()
    s.farAudio(5.0, 6.0)
    s.mic(5.2, 5.9, "Sounds good.", at: 7.0)
    s.far(5.0, 6.0, "Sounds good.", at: 8.2)
    s.advance(to: 20)
    check("two-word dup dropped", s.you.isEmpty)
}
do {  // different short words: both kept; released when the far commit passes it
    let s = CaptureSim()
    s.farAudio(10.0, 10.5)
    s.mic(10.1, 10.4, "Yeah.", at: 11.4)
    check("different word held while far text is behind", s.you.isEmpty && s.gate.heldCount == 1)
    s.far(10.0, 10.5, "Okay.", at: 12.6)
    check("different short word kept", s.you == ["Yeah."] && s.them == ["Okay."])
    check("released by the far commit, not the 3 s backstop", s.arrivedAt["Yeah."] == 12.6)
    check("kept line keeps its original time", s.transcript.first(where: \.isYou)?.t == 10.1)
}
do {  // same word outside the window: kept (real reply a beat later)
    let s = CaptureSim()
    s.farAudio(10.0, 10.4)
    s.far(10.0, 10.4, "Okay.", at: 12.5)
    s.farAudio(14.0, 15.0)   // guest talking again when the user replies
    s.mic(14.5, 14.9, "Okay.", at: 15.9)
    s.advance(to: 30); s.stop()
    check("same word outside window kept", s.you == ["Okay."])
}
do {  // user replies "Okay." after the guest went quiet: no hold at all
    let s = CaptureSim()
    s.farAudio(10.0, 10.4)
    s.far(10.0, 10.4, "Okay.", at: 12.5)
    s.mic(13.0, 13.4, "Okay.", at: 14.4)
    check("reply after far silence delivered immediately", s.you == ["Okay."] && s.gate.heldCount == 0)
}
do {  // short line while far side silent: never held, never dropped
    let s = CaptureSim()
    s.mic(3.0, 3.3, "Yeah.", at: 4.3)
    check("no far audio, delivered immediately", s.you == ["Yeah."])
}
do {  // same word said early in a long far chunk does not claim a reply at its end
    let s = CaptureSim()
    s.farAudio(0, 20)
    s.mic(19.0, 19.4, "Right.", at: 20.4)
    s.far(0, 20, "Right. And then we looked at the numbers for the whole quarter and the team agreed the plan works.", at: 22.5)
    s.advance(to: 30)
    check("word early in long Them chunk does not drop late reply", s.you == ["Right."])
}
do {  // headphones / any non-speaker route: unchanged
    let s = CaptureSim(onSpeakers: false)
    s.farAudio(10.0, 10.5)
    s.far(10.0, 10.5, "Okay.", at: 11.2)
    s.mic(10.1, 10.4, "Okay.", at: 11.6)
    check("headphones: short dup kept as before", s.you == ["Okay."] && s.gate.heldCount == 0)
    let s2 = CaptureSim(onSpeakers: false)
    s2.farAudio(10.0, 10.5)
    s2.mic(10.1, 10.4, "Okay.", at: 11.4)
    check("headphones: no hold", s2.you == ["Okay."])
    check("headphones: live partial never hidden",
          !s.gate.hidesPartial("Okay", onSpeakers: false, now: 11.0))
}
do {  // longer phrases: gate never touches them, EchoFilter unchanged
    let s = CaptureSim()
    s.farAudio(10, 11)
    s.far(10, 11, "That sounds right to me.", at: 12)
    s.mic(10, 11, "That sounds right to me.", at: 12.2)
    check("3+ word line bypasses gate", s.you == ["That sounds right to me."])
    let f = EchoFilter()
    f.clock = { at(0) }
    f.recordFarText("that sounds right to me")
    check("longer phrase still stripped by EchoFilter",
          f.filter("That sounds right to me.", since: at(-3)) == nil)
    f.recordFarText("okay")
    check("EchoFilter still keeps 1-2 words", f.filter("Okay.", since: at(-3))?.text == "Okay.")
}
do {  // a short line that only partly matches is kept
    let s = CaptureSim()
    s.farAudio(5, 6)
    s.mic(5.2, 5.9, "Okay. Sure.", at: 7)
    s.far(5, 6, "Okay. Yeah.", at: 8)
    s.advance(to: 20)
    check("partly matching short line kept", s.you == ["Okay. Sure."])
}
do {  // stop while a line is held: it reaches the transcript before the save
    let s = CaptureSim()
    s.farAudio(10.0, 10.5)
    s.mic(10.1, 10.4, "Thanks.", at: 11.4)
    s.stop()
    check("held line kept on stop", s.you == ["Thanks."] && s.gate.heldCount == 0 && s.late.isEmpty)
}
do {  // live pending line: the bleed partial is hidden once the twin is known
    let s = CaptureSim()
    s.farAudio(10, 10.5)
    s.farPartial("Okay.", at: 11)
    check("bleed partial hidden on speakers", s.gate.hidesPartial("Okay", onSpeakers: true, now: 11.2))
    check("other partial shown", !s.gate.hidesPartial("Yeah", onSpeakers: true, now: 11.2))
}

// -- Stop race (review of PR #77) --
do {  // (a) hold timer due, but its main block has not run when Stop executes
    let s = CaptureSim()
    s.farAudio(10.0, 12.0)
    s.mic(10.1, 10.4, "Thanks.", at: 11.4)
    s.advance(to: 11.4 + ShortEchoGate.holdSeconds + 0.5, holdMain: true)
    s.stop()
    check("stop race (a): overdue held line saved, not late",
          s.you == ["Thanks."] && s.late.isEmpty)
}
do {  // (a') early release marked by a far partial, main block not yet run
    let s = CaptureSim()
    s.farAudio(10.0, 13.0)
    s.mic(10.1, 10.4, "Thanks.", at: 11.4)
    s.advance(to: 12.5, holdMain: true)
    _ = s.gate.recordFarPartial("We can wrap up", now: 12.5)
    s.stop()
    check("stop race (a'): releasable line saved, not late",
          s.you == ["Thanks."] && s.late.isEmpty)
}
do {  // (b) a mic line still in deliver when Stop runs: never held after it
    let s = CaptureSim()
    s.farAudio(10.0, 12.0)
    s.advance(to: 11.0)
    s.stop()
    let d = s.mic(10.1, 10.4, "Thanks.", at: 11.4)
    s.advance(to: 20)
    check("stop race (b): line after drain passes straight through",
          d == .deliver && s.gate.heldCount == 0 && s.late.map(\.text) == ["Thanks."])
    // Held a moment before the drain: the drain returns it.
    let s2 = CaptureSim()
    s2.farAudio(10.0, 12.0)
    s2.mic(10.1, 10.4, "Thanks.", at: 11.4)
    s2.advance(to: 11.41, holdMain: true)
    s2.stop()
    check("stop race (b): line held just before the drain is saved",
          s2.you == ["Thanks."] && s2.late.isEmpty)
}

// -- Window is really ~2 s, partials included --
do {  // guest "Bye.", then keeps going; user's own "Bye." 3 s later is kept
    let s = CaptureSim()
    s.farAudio(10.0, 10.4)
    s.farPartial("Bye.", at: 11.2)
    s.farAudio(12.8, 13.6)
    s.mic(13.0, 13.3, "Bye.", at: 14.2)
    s.farPartial("Bye. Take care.", at: 14.6)
    s.far(10.0, 13.6, "Bye. Take care.", at: 15.8)
    s.advance(to: 30); s.stop()
    check("user's Bye. 3 s after the guest's kept", s.you == ["Bye."])
    check("guest's Bye. kept as Them", s.them == ["Bye. Take care."])
}
do {  // ...but a real bleed twin in the same shape is still dropped
    let s = CaptureSim()
    s.farAudio(10.0, 10.4)
    s.mic(10.05, 10.35, "Bye.", at: 11.3)
    s.farPartial("Bye.", at: 11.2 + 0.2)
    s.advance(to: 20); s.stop()
    check("simultaneous Bye. bleed still dropped", s.you.isEmpty)
}

// -- Partial revision does not refresh old words --
do {
    let s = CaptureSim()
    s.farAudio(10.0, 20.0)   // guest talks throughout
    s.farPartial("So we tested it. Yeah.", at: 12.0)
    s.farPartial("So we tested it. Yeah. That part works.", at: 14.0)
    // Recognizer revises the FIRST sentence; "Yeah." is unchanged.
    s.farPartial("So we tested this. Yeah. That part works. Great", at: 18.0)
    s.mic(17.0, 17.3, "Yeah.", at: 18.2)
    s.farPartial("So we tested this. Yeah. That part works. Great news", at: 19.0)
    s.advance(to: 30)
    check("revision before an old Yeah. does not eat the user's later Yeah.", s.you == ["Yeah."])
}

// -- Early release: genuine short replies are not held 3 s --
do {  // backchannel while the guest talks: released by the next far partial
    let s = CaptureSim()
    s.farAudio(10.0, 16.0)
    s.farPartial("We should move the", at: 12.0)
    let d = s.mic(12.0, 12.3, "Yeah.", at: 13.2)
    s.farPartial("We should move the launch to", at: 13.5)
    let delay = (s.arrivedAt["Yeah."] ?? .infinity) - 13.2
    check("backchannel held then released early", d == .hold && s.you == ["Yeah."])
    check("released \(String(format: "%.1f", delay)) s after the mic commit (< 1.5)", delay < 1.5)
}
do {  // far side starts talking only after the user's line: not held
    let s = CaptureSim()
    s.farAudio(6.0, 9.0)
    let d = s.mic(5.0, 5.3, "Sure.", at: 6.2)
    check("far voice after the line does not hold it", d == .deliver && s.you == ["Sure."])
}
do {  // far text already past the line when the mic commits: not held
    let s = CaptureSim()
    s.farAudio(10.0, 14.0)
    s.farPartial("Let me share my", at: 12.0)
    s.farPartial("Let me share my screen", at: 13.1)
    let d = s.mic(11.5, 11.8, "Okay.", at: 13.2)
    check("far text past the line delivers at once", d == .deliver && s.you == ["Okay."])
}

// -- Route change and degrade to mic-only release held lines --
do {
    let s = CaptureSim()
    s.farAudio(10.0, 12.0)
    s.mic(10.1, 10.4, "Thanks.", at: 11.4)
    s.gateOff(at: 11.6)   // headphones plugged in
    check("route change away from speakers delivers held line",
          s.you == ["Thanks."] && s.arrivedAt["Thanks."] == 11.6)
    s.farAudio(12.0, 13.0)
    let d = s.mic(12.1, 12.4, "Okay.", at: 13.4)
    check("after route change nothing is held", d == .deliver && s.gate.heldCount == 0)
}
do {
    let s = CaptureSim()
    s.farAudio(10.0, 12.0)
    s.mic(10.1, 10.4, "Right.", at: 11.4)
    s.gateOff(at: 12.0)   // system audio lost: mic-only
    s.mic(12.5, 12.8, "Okay.", at: 13.8)
    s.advance(to: 20); s.stop()
    check("degrade to mic-only delivers held line and holds nothing",
          s.you == ["Right.", "Okay."] && s.late.isEmpty)
}

exit(fail ? 1 : 0)
