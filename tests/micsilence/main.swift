import Foundation

// MicSilenceMonitor checks (pure logic, no audio). Field case 2026-10-07: a
// customer's mic delivered exact zeros in every meeting for two weeks; the
// zero-audio watchdog rebuilt capture 1,831 times and the user never heard
// about it. The monitor turns that into a warning.

var fail = false
func check(_ name: String, _ ok: Bool) {
    print("micsilence \(name): \(ok ? "PASS" : "FAIL")")
    if !ok { fail = true }
}

let base = Date(timeIntervalSinceReferenceDate: 1_000)
func at(_ t: TimeInterval) -> Date { base.addingTimeInterval(t) }
let warnAfter = MicSilenceMonitor.warnAfter

// 1. All-zero audio from the start warns after the grace period, not before.
do {
    var m = MicSilenceMonitor(start: at(0))
    for t in stride(from: 0.0, to: warnAfter, by: 0.1) { _ = m.observe(nonzero: false, at: at(t)) }
    check("no warning inside grace", !m.evaluate(now: at(warnAfter - 1), suppressed: false, permissionDenied: false) && m.warning == nil)
    check("warns after grace", m.evaluate(now: at(warnAfter), suppressed: false, permissionDenied: false) && m.warning == .noSignal)
    check("no repeat change while still silent", !m.evaluate(now: at(warnAfter + 3), suppressed: false, permissionDenied: false))
}

// 2. Real audio clears the warning at once, and the clock restarts from the
//    next silence — not from session start.
do {
    var m = MicSilenceMonitor(start: at(0))
    _ = m.evaluate(now: at(warnAfter + 1), suppressed: false, permissionDenied: false)
    check("observe nonzero reports clear", m.observe(nonzero: true, at: at(warnAfter + 2)) && m.warning == nil)
    _ = m.observe(nonzero: false, at: at(warnAfter + 3))
    check("fresh grace after recovery", !m.evaluate(now: at(warnAfter + 10), suppressed: false, permissionDenied: false))
    check("warns again after fresh grace",
          m.evaluate(now: at(2 * warnAfter + 3), suppressed: false, permissionDenied: false) && m.warning == .noSignal)
}

// 3. A mic that hears the room never warns.
do {
    var m = MicSilenceMonitor(start: at(0))
    for t in stride(from: 0.0, to: 120, by: 0.1) {
        _ = m.observe(nonzero: true, at: at(t))
    }
    check("live mic never warns", !m.evaluate(now: at(120), suppressed: false, permissionDenied: false) && m.warning == nil)
}

// 4. Capture rebuilds (every ~9 s for a zombie mic) restart the manager's
//    rebuild timer but never this monitor, so a session-long zombie still
//    warns at 30 s even though no single capture lived that long.
do {
    var m = MicSilenceMonitor(start: at(0))
    for t in stride(from: 0.0, to: warnAfter + 1, by: 9) { _ = m.observe(nonzero: false, at: at(t)) }
    check("zombie rebuilds still warn", m.evaluate(now: at(warnAfter + 1), suppressed: false, permissionDenied: false))
}

// 5. Denied mic access warns on the first check, with its own cause.
do {
    var m = MicSilenceMonitor(start: at(0))
    check("denied warns immediately", m.evaluate(now: at(3), suppressed: false, permissionDenied: true) && m.warning == .permissionDenied)
}

// 6. An Apple call zeroes the mic on purpose and has its own banner.
do {
    var m = MicSilenceMonitor(start: at(0))
    check("apple call suppresses", !m.evaluate(now: at(warnAfter * 2), suppressed: true, permissionDenied: false) && m.warning == nil)
    _ = m.evaluate(now: at(warnAfter * 2), suppressed: false, permissionDenied: false)
    check("suppression lifting clears to warning", m.warning == .noSignal)
    check("suppression mid-warning clears", m.evaluate(now: at(warnAfter * 3), suppressed: true, permissionDenied: false) && m.warning == nil)
}

// 7. Permission denied at the prompt mid-session switches the cause.
do {
    var m = MicSilenceMonitor(start: at(0))
    _ = m.evaluate(now: at(warnAfter), suppressed: false, permissionDenied: false)
    check("denied mid-session switches cause",
          m.evaluate(now: at(warnAfter + 3), suppressed: false, permissionDenied: true)
          && m.warning == .permissionDenied)
}

// 8. A mic that worked, then stopped delivering buffers entirely (dead
//    device): the watchdog reports the last buffer time as silence start,
//    so the warning fires 30 s after the last buffer.
do {
    var m = MicSilenceMonitor(start: at(0))
    _ = m.observe(nonzero: true, at: at(600))
    _ = m.observe(nonzero: false, at: at(600))   // watchdog: no buffers since 600
    _ = m.observe(nonzero: false, at: at(615))   // later rebuild: keeps the earlier start
    check("no buffers inside grace", !m.evaluate(now: at(620), suppressed: false, permissionDenied: false))
    check("no buffers warns 30 s after last buffer",
          m.evaluate(now: at(600 + warnAfter), suppressed: false, permissionDenied: false)
          && m.warning == .noSignal)
}

if fail { print("MIC SILENCE CHECKS FAILED"); exit(1) }
print("All mic silence checks passed.")
