import Foundation
import WhisperKit

/// Trims leading and trailing silence before transcription (§5.3).
///
/// This is the cheapest latency win available: Whisper pads every clip to a
/// 30-second window internally, so seconds of silence at either end are
/// seconds of inference spent on nothing.
///
/// The spec plans for Silero via onnxruntime. WhisperKit already ships an
/// energy VAD, which means no extra dependency and no ~2 MB model to bundle —
/// so that is what this uses. Silero would slot in behind the same function if
/// noisy rooms ever prove the energy gate is not enough.
public enum VoiceActivityTrimmer {

    public struct Result: Sendable, Equatable {
        public var samples: [Float]
        public var trimmedLeadingSeconds: Double
        public var trimmedTrailingSeconds: Double

        public var totalTrimmedSeconds: Double {
            trimmedLeadingSeconds + trimmedTrailingSeconds
        }
    }

    /// Padding kept around detected speech so the gate cannot clip a soft
    /// consonant at the start or end of an utterance.
    static let paddingSeconds: Double = 0.12

    /// Returns nil when the clip contains no speech at all — the caller turns
    /// that into "nothing heard" rather than paying for a transcription that
    /// will come back empty.
    public static func trim(_ samples: [Float],
                            sensitivity: Double,
                            sampleRate: Double = AudioRecorder.sampleRate) -> Result? {
        guard !samples.isEmpty else { return nil }

        let vad = EnergyVAD(sampleRate: Int(sampleRate),
                            frameLength: 0.1,
                            frameOverlap: 0.0,
                            energyThreshold: energyThreshold(for: sensitivity))

        let activity = vad.voiceActivity(in: samples)
        guard let firstActive = activity.firstIndex(of: true),
              let lastActive = activity.lastIndex(of: true)
        else { return nil }

        let frame = vad.frameLengthSamples
        let padding = Int(Self.paddingSeconds * sampleRate)

        let start = max(0, firstActive * frame - padding)
        let end = min(samples.count, (lastActive + 1) * frame + padding)
        guard start < end else { return nil }

        return Result(
            samples: Array(samples[start..<end]),
            trimmedLeadingSeconds: Double(start) / sampleRate,
            trimmedTrailingSeconds: Double(samples.count - end) / sampleRate)
    }

    /// Maps the 0…1 slider onto an energy threshold.
    ///
    /// Inverted: a *more* sensitive setting must detect quieter speech, which
    /// means a *lower* threshold. Midpoint lands near WhisperKit's own 0.02
    /// default so the middle of the slider is the tuned value.
    static func energyThreshold(for sensitivity: Double) -> Float {
        let clamped = min(1, max(0, sensitivity))
        return Float(0.05 - clamped * 0.048)
    }
}
