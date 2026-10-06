import Foundation

/// Only extracted active-tile names survive OCR. No images or raw window text.
struct VisualSpeakerObservation: Sendable {
    let name: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Recompute against the latest diarization: finalized segments can be revised.
/// Two independent snapshots must agree; any competing mapping vetoes the pair.
enum VisualSpeakerEvidence {
    static func matches(_ observations: [VisualSpeakerObservation],
                        segments: [SpeakerSegment], localSpeech: [Utterance]) -> [(label: String, name: String)] {
        var votes: [String: [String: Set<TimeInterval>]] = [:]
        var names: [String: String] = [:]
        for o in observations {
            guard o.end >= o.start, o.end - o.start <= 1 else { continue }
            let lo = o.start - 0.75, hi = o.end + 0.75
            guard !localSpeech.contains(where: { $0.isYou && $0.t < hi && $0.endT > lo }) else { continue }
            let overlap = segments.filter { $0.start < hi && $0.end > lo }
            let labels = Set(overlap.map(\.speaker))
            guard labels.count == 1, let label = labels.first,
                  label.wholeMatch(of: #/^Them \d+$/#) != nil,
                  overlap.contains(where: { $0.start <= lo && $0.end >= hi }) else { continue }
            let key = o.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            names[key] = o.name
            votes[label, default: [:]][key, default: []].insert(o.start)
        }
        return votes.keys.sorted().compactMap { label in
            guard let candidates = votes[label], candidates.count == 1,
                  let (key, times) = candidates.first, times.count >= 2,
                  (times.max() ?? 0) - (times.min() ?? 0) >= 10,
                  votes.filter({ $0.value[key] != nil }).count == 1,
                  let name = names[key] else { return nil }
            return (label, name)
        }
    }
}
