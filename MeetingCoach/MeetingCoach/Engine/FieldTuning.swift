import Foundation

/// Per-signal sensitivity multipliers learned across users who opted in to
/// "Help improve coaching" (decisions.md 2026-11-02 "coaching feedback").
/// Same convention and reach as AdaptiveThresholds: >1 relaxes the signal
/// (fewer nudges), <1 tightens it, applied to BOTH the threshold and the
/// cooldown — most monitors only expose a cooldown knob. Folded into the
/// active rubric at session start, beneath focus goals and each user's own
/// adaptive multipliers.
///
/// EDITED BY scripts/improve/propose.py via the weekly improve workflow,
/// which moves a value at most 10% per run and opens a PR — never merges.
/// Keep the marker lines and the one-entry-per-line shape.
enum FieldTuning {
    static let clampRange = 0.67...1.5

    // BEGIN FIELD TUNING
    static let multipliers: [String: Double] = [:]
    // END FIELD TUNING

    static func multiplier(forKey key: String) -> Double {
        min(max(multipliers[key] ?? 1.0, clampRange.lowerBound), clampRange.upperBound)
    }

    /// The rubric tuning with field multipliers folded in. An empty table is
    /// byte-identical to the input.
    static func applied(to tuning: RubricTuning) -> RubricTuning {
        var out = tuning
        for key in multipliers.keys {
            var t = out[key] ?? SignalTuning()
            let m = multiplier(forKey: key)
            t.thresholdMultiplier *= m
            t.cooldownMultiplier *= m
            out[key] = t
        }
        return out
    }
}
