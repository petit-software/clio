import Foundation
import ArgmaxCore
import SpeakerKit

/// The three small Core ML models that tell voices apart — a segmenter, an
/// embedder and a projector, Pyannote's, packaged by Argmax — and where they
/// sit in the folder Clio installs them to.
///
/// They come from one repo that holds every variant of each. Which variant
/// SpeakerKit loads depends on the macOS it runs on, so this asks SpeakerKit
/// rather than naming them: what is downloaded and what counts as installed
/// are then the same answer as what will be loaded.
public enum SpeakerModels {

    /// What SpeakerKit will load on this Mac.
    static var required: [ModelInfo] { [.segmenter(), .embedder(), .plda()] }

    /// The compiled models each of those folders must hold.
    static let compiledModels: [String: [String]] = [
        "speaker_segmenter": ["SpeakerSegmenter"],
        "speaker_embedder": ["SpeakerEmbedder", "SpeakerEmbedderPreprocessor"],
        "speaker_clusterer": ["PldaProjector"],
    ]

    /// The embedder this Mac loads, as a name: what its voiceprints are
    /// marked with. A newer macOS that picks another variant makes vectors
    /// that mean something else.
    public static var embeddingSpace: String {
        let embedder = ModelInfo.embedder()
        return [embedder.name, embedder.version, embedder.variant].compactMap { $0 }
            .joined(separator: "/")
    }

    /// The folders of the repo worth downloading: what this Mac loads, and
    /// the segmenter's other variant, so the models are still whole after
    /// an upgrade to the macOS that prefers it.
    static var folders: [String] {
        var infos = required
        infos.append(.segmenter(variant: "W8A16"))
        infos.append(.segmenter(variant: "W32A32"))
        let root = URL(fileURLWithPath: "/")
        return Array(Set(infos.map { String($0.modelURL(baseURL: root).path.dropFirst()) })).sorted()
    }

    /// Whether a file of the repo is one to download.
    public static func wants(path: String) -> Bool {
        folders.contains { path.hasPrefix($0 + "/") }
    }

    /// Whether `folder` holds every model this Mac loads, whole: each
    /// compiled model with its weights. The weights are the last file of a
    /// model to arrive, so a download that stopped halfway is not installed.
    public static func isInstalled(at folder: URL) -> Bool {
        required.allSatisfy { info in
            let directory = info.modelURL(baseURL: folder)
            return (compiledModels[info.name] ?? []).allSatisfy { name in
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("\(name).mlmodelc/weights/weight.bin").path)
            }
        }
    }

    /// Whether a folder is a speaker-model folder at all, whole or not.
    static func isSpeakerFolder(_ folder: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("speaker_segmenter").path)
    }
}

/// Tells the voices in a recording of a call apart, with SpeakerKit.
///
/// Configured like the speech engine: a folder Clio installed, and
/// `download: false`, so nothing here reaches for the network. The models
/// are loaded for one meeting and let go again — they are needed once, at
/// its end.
public actor SpeakerDiarizer: SpeakerDiarizing {

    public enum DiarizerError: LocalizedError {
        case modelsMissing

        public var errorDescription: String? {
            "The speaker model is not installed."
        }
    }

    /// The models work on thirty seconds at a time.
    static let windowSamples = 30 * 16_000
    /// About −70 dBFS: under any voice, over nothing at all.
    static let noiseAmplitude: Float = 0.0003

    /// The recording with its digital silence — exact zeros — replaced by
    /// very quiet noise, and its end filled out with the same to a whole
    /// window.
    ///
    /// Not cosmetic. The recording is zeros wherever the tap sent nothing:
    /// before the call's first sound, and through every stretch nothing
    /// played. A turn that came after forty seconds of zeros was heard as
    /// a different person from the same voice's later turns — as far from
    /// them as from the other speaker (0.86 against 0.89) — and the last
    /// turns of a recording split off the same way, where the final window
    /// is padded. With noise in place of the zeros neither happens: 48
    /// turns of two voices, all on the right one (`SpeakerIntegration`).
    /// Presumably the features are normalised over a window, and a window
    /// that is mostly nothing at all skews them; that is a guess, the
    /// measurements are not.
    static func withoutDigitalSilence(_ samples: [Float]) -> [Float] {
        var result = samples
        removeDigitalSilence(&result)
        return result
    }

    static func removeDigitalSilence(_ result: inout [Float]) {
        // Seeded, so one recording always gives one answer.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func noise() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)      // 0..<1
            return (unit * 2 - 1) * noiseAmplitude
        }
        for index in result.indices where result[index] == 0 { result[index] = noise() }
        let tail = result.count % windowSamples
        if tail != 0 {
            result.reserveCapacity(result.count + windowSamples - tail)
            for _ in 0..<(windowSamples - tail) { result.append(noise()) }
        }
    }

    private let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func diarize(recording file: URL) async throws -> Diarization {
        guard SpeakerModels.isInstalled(at: folder) else { throw DiarizerError.modelsMissing }
        // One copy of the call in memory, changed in place: an hour is
        // 230 MB as samples, and the models need the same again of their own.
        var samples = try StreamRecording.samples(at: file)
        // Digital silence from end to end — nobody else spoke, or the tap
        // was refused — has no voices in it to find.
        guard samples.contains(where: { $0 != 0 }) else { return Diarization(spans: []) }
        Self.removeDigitalSilence(&samples)
        return try await diarize(prepared: samples)
    }

    /// 16 kHz mono samples, already through `removeDigitalSilence`; time
    /// zero is the first of them.
    private func diarize(prepared samples: [Float]) async throws -> Diarization {

        let kit = try await SpeakerKit(PyannoteConfig(
            modelFolder: folder.path, download: false, load: true, verbose: false))
        // Centroids from the stretches where a voice is alone: fewer, but
        // they are the voice and not a mix of two. A voice always talked
        // over gets none, and is still in the spans.
        let result: DiarizationResult
        do {
            result = try await kit.diarize(
                audioArray: samples,
                options: PyannoteDiarizationOptions(centroidSource: .trainableOnly))
        } catch {
            await kit.unloadModels()
            throw error
        }
        await kit.unloadModels()

        let spans = result.segments.compactMap { segment -> SpeakerSpan? in
            guard let speaker = segment.speaker.speakerId else { return nil }
            return SpeakerSpan(speaker: speaker, start: Double(segment.startTime),
                               end: Double(segment.endTime))
        }
        return Diarization(spans: spans, voiceprints: result.speakerCentroidEmbeddings,
                           space: SpeakerModels.embeddingSpace)
    }
}
