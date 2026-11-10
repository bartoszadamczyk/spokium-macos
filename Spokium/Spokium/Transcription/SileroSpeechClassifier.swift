import Foundation
import OSLog
import whisper

// Silero VAD (bundled, ~0.9 MB) through whisper.cpp's streaming VAD API. Unlike the RMS
// check it tells speech from keyboard clicks, breathing and room noise, so the chunker
// cuts at real pauses and noise-only stretches never reach whisper.
//
// Streaming: whisper_vad_detect_speech_no_reset keeps the LSTM state between calls, so
// feeding 500 ms batches gives the same probabilities as one long pass.
nonisolated final class SileroSpeechClassifier: SpeechClassifier {
    // Silero's frame at 16 kHz.
    let windowSamples = 512

    // Hysteresis so a word's soft tail doesn't flicker into "silence" and trigger a
    // premature cut. Below Silero's usual 0.5 / 0.35: whispering scores lower than voiced
    // speech, and dropping a quiet dictation is worse than one extra whisper call (whose
    // no-speech filter still catches noise).
    private let startThreshold: Float = 0.3
    private let endThreshold: Float = 0.15

    private let context: OpaquePointer
    private var inSpeech = false
    private let fallback = RMSSpeechClassifier(windowSamples: 512)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Spokium", category: "VAD")

    static var bundledModelURL: URL? {
        Bundle.main.url(forResource: "ggml-silero-v6.2.0", withExtension: "bin")
    }

    init?(modelURL: URL? = SileroSpeechClassifier.bundledModelURL) {
        guard let modelURL else { return nil }
        Transcriber.suppressWhisperLogs()
        var params = whisper_vad_default_context_params()
        // Tiny model: CPU is fast enough and keeps it off the GPU whisper is using.
        params.use_gpu = false
        params.n_threads = 1
        guard let context = whisper_vad_init_from_file_with_params(modelURL.path, params) else {
            return nil
        }
        self.context = context
    }

    deinit {
        whisper_vad_free(context)
    }

    func classify(_ samples: ArraySlice<Float>) -> [Bool] {
        guard let probs = probabilities(samples) else {
            logger.error("VAD failed on \(samples.count / self.windowSamples) windows; using RMS for this batch")
            return fallback.classify(samples)
        }
        return probs.map { p in
            inSpeech = p >= (inSpeech ? endThreshold : startThreshold)
            return inSpeech
        }
    }

    // Raw per-window speech probabilities (continues the streaming state).
    func probabilities(_ samples: ArraySlice<Float>) -> [Float]? {
        let windows = samples.count / windowSamples
        guard windows > 0 else { return [] }
        let ok = samples.withContiguousStorageIfAvailable { buffer in
            whisper_vad_detect_speech_no_reset(context, buffer.baseAddress, Int32(windows * windowSamples))
        } ?? Array(samples).withUnsafeBufferPointer { buffer in
            whisper_vad_detect_speech_no_reset(context, buffer.baseAddress, Int32(windows * windowSamples))
        }
        guard ok, Int(whisper_vad_n_probs(context)) == windows, let probs = whisper_vad_probs(context) else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: probs, count: windows))
    }

    func reset() {
        whisper_vad_reset_state(context)
        inSpeech = false
    }
}
