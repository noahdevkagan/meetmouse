import Foundation

/// Keep only solo speech when collecting a voice profile from a mixed
/// channel. Speaker separation identifies timing; it does not remove the
/// other person's audio from the samples we save.
enum VoiceClipSelection {
    static func soloRanges(start: TimeInterval, end: TimeInterval,
                           excluding others: [Range<TimeInterval>]) -> [Range<TimeInterval>] {
        guard end > start else { return [] }
        var cursor = start
        var result: [Range<TimeInterval>] = []
        for other in others.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard other.upperBound > cursor else { continue }
            guard other.lowerBound < end else { break }
            if other.lowerBound > cursor {
                result.append(cursor..<other.lowerBound)
            }
            cursor = max(cursor, other.upperBound)
            if cursor >= end { return result }
        }
        if cursor < end { result.append(cursor..<end) }
        return result
    }
}
