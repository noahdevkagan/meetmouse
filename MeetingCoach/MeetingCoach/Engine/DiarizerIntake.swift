import Accelerate
import Foundation

/// Streaming FIR decimator (windowed-sinc low-pass + downsample via
/// vDSP_desamp). Capture hands us 48kHz mono but the LS-EEND model runs at
/// 16kHz — decimating once at the boundary cuts ring/preload/clip memory
/// and the model's internal resampling work by the factor, at identical
/// quality. Integer factors only; other rates pass through untouched.
struct Decimator {
    let factor: Int
    private let filter: [Float]
    /// Tail of the previous buffer, so the FIR window never sees a seam.
    private var carry: [Float] = []

    init?(inputRate: Double, targetRate: Double) {
        guard inputRate > targetRate,
              inputRate.truncatingRemainder(dividingBy: targetRate) == 0 else { return nil }
        factor = Int(inputRate / targetRate)
        // 31-tap Hamming-windowed sinc, cutoff at 0.9× the new Nyquist.
        let taps = 31
        let m = Double(taps - 1)
        let fc = 0.45 / Double(factor)
        var h = [Double](repeating: 0, count: taps)
        for n in 0..<taps {
            let x = Double(n) - m / 2
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            h[n] = sinc * (0.54 - 0.46 * cos(2 * .pi * Double(n) / m))
        }
        let gain = h.reduce(0, +)
        filter = h.map { Float($0 / gain) }
    }

    mutating func process(_ samples: [Float]) -> [Float] {
        let input = carry + samples
        let taps = filter.count
        guard input.count >= taps else {
            carry = input
            return []
        }
        let outCount = (input.count - taps) / factor + 1
        var out = [Float](repeating: 0, count: outCount)
        vDSP_desamp(input, vDSP_Stride(factor), filter, &out,
                    vDSP_Length(outCount), vDSP_Length(taps))
        carry = Array(input[(outCount * factor)...])
        return out
    }
}

/// What the diarizer is fed: source buffers brought to the model rate, and
/// silence for stretches where capture delivered nothing. Kept apart from
/// SpeakerDiarizer (which needs the CoreML model) so the session clock it
/// produces can be checked without one.
struct DiarizerIntake {
    let modelRate: Double
    private var decimator: Decimator?
    /// The source rate `decimator` was built for.
    private var sourceRate: Double?

    init(modelRate: Double = 16_000) {
        self.modelRate = modelRate
    }

    /// A source buffer, decimated to the model rate when the source rate is
    /// an integer multiple of it; other rates pass through for the model to
    /// resample. Nil while the FIR filter is still warming up.
    ///
    /// The decimator follows the source: a microphone that comes back at a
    /// different rate after a restart (AirPods at 24 kHz after a 48 kHz
    /// start) gets a new one. Reusing the first buffer's factor ran the
    /// session clock slow for the rest of the call.
    mutating func audio(_ samples: [Float], sampleRate: Double) -> (samples: [Float], rate: Double)? {
        if sourceRate != sampleRate {
            decimator = Decimator(inputRate: sampleRate, targetRate: modelRate)
            sourceRate = sampleRate
        }
        guard var active = decimator else { return (samples, sampleRate) }
        let out = active.process(samples)
        decimator = active
        return out.isEmpty ? nil : (out, modelRate)
    }

    /// Silence covering `seconds` of session time, as whole one-second
    /// chunks plus a remainder, so a long gap (the Mac slept mid-call) is
    /// never one allocation. Sized at the model rate, past the decimator:
    /// sent through `audio` as 16 kHz samples, a 48 kHz source's decimator
    /// shrank it to a third of the gap, and every later speaker segment
    /// landed that much too early.
    func silence(seconds: TimeInterval) -> SilencePlan {
        let total = max(0, Int((seconds * modelRate).rounded()))
        let chunk = max(1, Int(modelRate))
        return SilencePlan(chunk: chunk, fullChunks: total / chunk,
                           remainder: total % chunk, rate: modelRate)
    }

    struct SilencePlan: Equatable {
        /// Samples in one full chunk (one second at the model rate).
        let chunk: Int
        let fullChunks: Int
        let remainder: Int
        let rate: Double

        var samples: Int { chunk * fullChunks + remainder }
    }
}
