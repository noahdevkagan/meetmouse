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
// deliver them (mic commit, Them partial, Them commit, hold timer, stop) and
// go through the same gate calls AudioCaptureManager makes. `transcript` is
// what reaches the session (onUtterance + the stop drain), i.e. what the UI,
// signals, talk stats and the saved file all consume. Session-relative clock.
final class CaptureSim {
    let gate = ShortEchoGate()
    var onSpeakers: Bool
    var now: TimeInterval = 0
    var farLoudAt: TimeInterval = -.infinity
    var transcript: [Utterance] = []
    private var timers: [TimeInterval] = []

    init(onSpeakers: Bool = true) { self.onSpeakers = onSpeakers }

    /// Far audio audible over [from, to] (the system buffer RMS stamp).
    func farAudio(_ from: TimeInterval, _ to: TimeInterval) { farLoudAt = max(farLoudAt, to) }

    func mic(_ t: TimeInterval, _ end: TimeInterval, _ text: String, at: TimeInterval) {
        advance(to: at)
        let u = Utterance(t: t, speaker: "You", text: text, endT: end)
        switch gate.submit(u, onSpeakers: onSpeakers, farLoudAt: farLoudAt, now: now) {
        case .drop: break
        case .hold: timers.append(now + ShortEchoGate.holdSeconds + 0.05)
        case .deliver: transcript.append(u)
        }
    }
    func farPartial(_ text: String, at: TimeInterval) {
        advance(to: at)
        _ = gate.recordFarPartial(text, now: now)
    }
    func far(_ t: TimeInterval, _ end: TimeInterval, _ text: String, at: TimeInterval) {
        advance(to: at)
        _ = gate.recordFarPartial("", now: now)   // commit clears the partial
        _ = gate.recordFar(Utterance(t: t, speaker: "Them", text: text, endT: end))
        farAudio(t, end)
        transcript.append(Utterance(t: t, speaker: "Them", text: text, endT: end))
    }
    func advance(to t: TimeInterval) {
        now = max(now, t)
        let due = timers.filter { $0 <= now }
        timers.removeAll { $0 <= now }
        for _ in due { transcript += gate.expire(now: now) }
    }
    func stop() { transcript += gate.drainAll() }
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
    check("dropped at once on partial evidence", s.gate.heldCount == 0)
    // Guest keeps talking: the commit only comes much later.
    s.far(10.0, 18.0, "Okay. So the plan for next week is simple.", at: 20.5)
    s.advance(to: 30); s.stop()
    check("short dup dropped via partial, late commit", s.you.isEmpty && s.them.count == 1)
}
do {  // mic first, guest continues: twin only in partials, no commit within the hold
    let s = CaptureSim()
    s.farAudio(10.0, 10.5)
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
do {  // different short words: both kept, mic line delivered after the hold
    let s = CaptureSim()
    s.farAudio(10.0, 10.5)
    s.mic(10.1, 10.4, "Yeah.", at: 11.4)
    s.far(10.0, 10.5, "Okay.", at: 12.6)
    check("different word waits for the hold", s.you.isEmpty && s.gate.heldCount == 1)
    s.advance(to: 11.4 + ShortEchoGate.holdSeconds + 0.1)
    check("different short word kept", s.you == ["Yeah."] && s.them == ["Okay."])
    check("kept line keeps its original time", s.transcript.first(where: \.isYou)?.t == 10.1)
}
do {  // same word outside the window: kept (real reply a beat later)
    let s = CaptureSim()
    s.far(10.0, 10.4, "Okay.", at: 12.5)
    s.farAudio(14.0, 15.0)   // guest talking again when the user replies
    s.mic(14.5, 14.9, "Okay.", at: 15.9)
    s.advance(to: 30); s.stop()
    check("same word outside window kept", s.you == ["Okay."])
}
do {  // user replies "Okay." after the guest went quiet: no hold at all
    let s = CaptureSim()
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
    check("held line kept on stop", s.you == ["Thanks."] && s.gate.heldCount == 0)
}
do {  // live pending line: the bleed partial is hidden once the twin is known
    let s = CaptureSim()
    s.farAudio(10, 10.5)
    s.farPartial("Okay.", at: 11)
    check("bleed partial hidden on speakers", s.gate.hidesPartial("Okay", onSpeakers: true, now: 11.2))
    check("other partial shown", !s.gate.hidesPartial("Yeah", onSpeakers: true, now: 11.2))
}

exit(fail ? 1 : 0)
