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
// The capture manager only submits mic lines when the route is built-in
// speakers; on any other route the gate is never consulted, so every short
// line is delivered untouched (modelled below as "never submitted").
func u(_ t: TimeInterval, _ end: TimeInterval, _ speaker: String, _ text: String) -> Utterance {
    Utterance(t: t, speaker: speaker, text: text, endT: end)
}
let t0 = Date(timeIntervalSinceReferenceDate: 5_000)

// Them copy first, then mic copy: dropped at once.
do {
    let g = ShortEchoGate()
    g.recordFar(u(10.0, 10.4, "Them", "Okay."))
    check("short dup dropped (Them first)",
          g.submit(u(10.2, 10.6, "You", "Okay."), now: t0) == .drop && g.heldCount == 0)
}

// Mic copy first: held, then dropped when the Them copy lands; never delivered.
do {
    let g = ShortEchoGate()
    check("mic first is held", g.submit(u(10.0, 10.4, "You", "Okay."), now: t0) == .hold)
    let dropped = g.recordFar(u(10.1, 10.5, "Them", "Okay."))
    check("short dup dropped (mic first)", dropped.count == 1 && g.heldCount == 0)
    check("dropped line never expires into the transcript",
          g.expire(now: t0.addingTimeInterval(10)).isEmpty)
}

// Different short words are kept (after the hold, with no twin).
do {
    let g = ShortEchoGate()
    g.recordFar(u(10, 10.4, "Them", "Okay."))
    check("different word is held, not dropped",
          g.submit(u(10.2, 10.6, "You", "Yeah."), now: t0) == .hold)
    check("different word delivered on expiry",
          g.expire(now: t0.addingTimeInterval(ShortEchoGate.holdSeconds)).map(\.text) == ["Yeah."])
}

// Same word outside the window is kept.
do {
    let g = ShortEchoGate()
    g.recordFar(u(10, 10.4, "Them", "Okay."))
    check("same word far outside window held then kept",
          g.submit(u(10.4 + ShortEchoGate.window + 1, 14, "You", "Okay."), now: t0) == .hold)
    check("kept on expiry",
          g.expire(now: t0.addingTimeInterval(ShortEchoGate.holdSeconds)).count == 1)
    let g2 = ShortEchoGate()
    _ = g2.submit(u(30, 30.4, "You", "Okay."), now: t0)
    check("late Them twin outside window does not retract",
          g2.recordFar(u(10, 10.4, "Them", "Okay.")).isEmpty && g2.heldCount == 1)
    let g3 = ShortEchoGate()
    g3.recordFar(u(10, 10.4, "Them", "Okay."))
    check("gap just inside window is echo",
          g3.submit(u(10.4 + ShortEchoGate.window - 0.1, 13, "You", "Okay."), now: t0) == .drop)
}

// Two-word lines and multi-sentence short lines.
do {
    let g = ShortEchoGate()
    g.recordFar(u(5, 6, "Them", "Okay. Yeah."))
    check("two sentences each matched are dropped",
          g.submit(u(5.2, 6.1, "You", "Okay. Yeah."), now: t0) == .drop)
    check("partly matching short line is not dropped",
          g.submit(u(5.2, 6.1, "You", "Okay. Sure."), now: t0) == .hold)
}

// A far utterance that merely contains the word is not a twin.
do {
    let g = ShortEchoGate()
    g.recordFar(u(10, 12, "Them", "Okay so let us start with the agenda."))
    check("containing sentence is not a twin",
          g.submit(u(10.5, 10.9, "You", "Okay."), now: t0) == .hold)
}

// Longer mic lines are not the gate's business; EchoFilter behaviour unchanged.
do {
    let g = ShortEchoGate()
    g.recordFar(u(10, 11, "Them", "That sounds right to me."))
    check("3+ word line bypasses gate",
          g.submit(u(10, 11, "You", "That sounds right to me."), now: t0) == .deliver)
    let f = EchoFilter()
    f.clock = { at(0) }
    f.recordFarText("that sounds right to me")
    check("longer phrase still stripped by EchoFilter",
          f.filter("That sounds right to me.", since: at(-3)) == nil)
    f.recordFarText("okay")
    check("EchoFilter still keeps 1-2 words", f.filter("Okay.", since: at(-3))?.text == "Okay.")
}

// Held lines are never lost on route change / stop.
do {
    let g = ShortEchoGate()
    _ = g.submit(u(1, 1.4, "You", "Right."), now: t0)
    check("flushAll returns held", g.flushAll().count == 1 && g.heldCount == 0)
}

exit(fail ? 1 : 0)
