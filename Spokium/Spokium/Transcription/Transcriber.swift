import Foundation
import Synchronization
import whisper

struct TranscriptionSettings: Sendable {
    var language: String = "auto"
    var paragraphSplitting: Bool = true
    var minSilenceDuration: Double = 3.0
}

struct TranscriptionResult: Sendable {
    let text: String
    let language: String
    // Per-segment whisper output, populated only when AppDefaults.debugMode is on.
    // Consumers (TranscriptionQueue) write this alongside the audio file as a
    // sidecar markdown log so debug data lives in one place on disk.
    let debugSegments: [DebugSegment]?
}

struct DebugSegment: Sendable {
    let index: Int32
    let startSeconds: Double
    let endSeconds: Double
    let noSpeechProb: Float
    let text: String
}

// Mirrors the metadata we log to OSLog on every successful transcription. Written
// into the debug sidecar markdown when debug mode is on so the file is a
// complete record of what happened, not just the per-segment breakdown.
struct DebugMetadata: Sendable {
    let modelStem: String
    let language: String
    let charCount: Int
    let totalAudioSeconds: Double
    let recordingSeconds: Double
    let transcriptionSeconds: Double
}

enum TranscriberError: Error {
    case modelLoadFailed
    case inferenceFailed(Int32)
    case cancelled
}

private final class WhisperContext: @unchecked Sendable {
    nonisolated(unsafe) let pointer: OpaquePointer
    nonisolated init(pointer: OpaquePointer) { self.pointer = pointer }
    deinit { whisper_free(pointer) }
}

private final class AbortFlag: Sendable {
    let value = Atomic<Bool>(false)
}

actor Transcriber {
    let modelURL: URL
    private var context: WhisperContext?
    nonisolated private let abortFlag = AbortFlag()

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    nonisolated func abort() {
        abortFlag.value.store(true, ordering: .relaxed)
    }

    func transcribe(
        audioURL: URL,
        initialPrompt: String? = nil,
        settings: TranscriptionSettings = TranscriptionSettings()
    ) throws -> TranscriptionResult {
        let samples = try AudioLoader.loadResampled(url: audioURL)
        return try transcribe(samples: samples, initialPrompt: initialPrompt, settings: settings)
    }

    func transcribe(
        samples: [Float],
        initialPrompt: String? = nil,
        settings: TranscriptionSettings = TranscriptionSettings()
    ) throws -> TranscriptionResult {
        let ctx = try loadedContext()
        abortFlag.value.store(false, ordering: .relaxed)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.no_context = true
        params.translate = false
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))

        params.abort_callback = { userData in
            guard let userData else { return false }
            let flag = Unmanaged<AbortFlag>.fromOpaque(userData).takeUnretainedValue()
            return flag.value.load(ordering: .relaxed)
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abortFlag).toOpaque()

        let langPtr: UnsafeMutablePointer<CChar>?
        if settings.language == "auto" {
            langPtr = nil
            params.language = nil
        } else {
            langPtr = strdup(settings.language)
            params.language = UnsafePointer(langPtr)
        }
        defer { free(langPtr) }

        let promptPtr = initialPrompt.flatMap { strdup($0) }
        defer { free(promptPtr) }
        params.initial_prompt = UnsafePointer(promptPtr)

        let status = samples.withUnsafeBufferPointer { ptr in
            whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
        }
        if abortFlag.value.load(ordering: .relaxed) {
            throw TranscriberError.cancelled
        }
        guard status == 0 else { throw TranscriberError.inferenceFailed(status) }

        let langId = whisper_full_lang_id(ctx)
        let language: String
        if let cStr = whisper_lang_str(langId) {
            language = String(cString: cStr)
        } else {
            language = "unknown"
        }

        let text: String
        if settings.paragraphSplitting {
            let silenceBreaks = SilenceDetector.breaks(
                samples: samples,
                sampleRate: 16000,
                minSilenceDuration: settings.minSilenceDuration
            )
            text = buildTextWithParagraphs(ctx: ctx, silenceBreaks: silenceBreaks)
        } else {
            text = buildPlainText(ctx: ctx)
        }

        let debugSegments: [DebugSegment]? = AppDefaults.debugMode ? collectDebugSegments(ctx: ctx) : nil

        return TranscriptionResult(text: text, language: language, debugSegments: debugSegments)
    }

    func tokenCount(for text: String) throws -> Int {
        let ctx = try loadedContext()
        return Int(whisper_token_count(ctx, text))
    }

    func unload() {
        context = nil
    }

    private func collectDebugSegments(ctx: OpaquePointer) -> [DebugSegment] {
        let n = whisper_full_n_segments(ctx)
        var out: [DebugSegment] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            let t0 = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0
            let t1 = Double(whisper_full_get_segment_t1(ctx, i)) / 100.0
            let noSpeechProb = whisper_full_get_segment_no_speech_prob(ctx, i)
            let text: String
            if let cString = whisper_full_get_segment_text(ctx, i) {
                text = String(cString: cString)
            } else {
                text = ""
            }
            out.append(DebugSegment(
                index: i,
                startSeconds: t0,
                endSeconds: t1,
                noSpeechProb: noSpeechProb,
                text: text
            ))
        }
        return out
    }

    private static let noSpeechThreshold: Float = 0.6

    private func keptSegmentIndices(ctx: OpaquePointer) -> [Int32] {
        let n = whisper_full_n_segments(ctx)
        return (0..<n).filter { i in
            whisper_full_get_segment_no_speech_prob(ctx, i) <= Self.noSpeechThreshold
        }
    }

    private func buildPlainText(ctx: OpaquePointer) -> String {
        var result = ""
        for i in keptSegmentIndices(ctx: ctx) {
            if let cString = whisper_full_get_segment_text(ctx, i) {
                result += String(cString: cString)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildTextWithParagraphs(ctx: OpaquePointer, silenceBreaks: [Double]) -> String {
        let kept = keptSegmentIndices(ctx: ctx)
        guard !kept.isEmpty else { return "" }

        var result = ""

        for (idx, i) in kept.enumerated() {
            if idx > 0 {
                let prev = kept[idx - 1]
                let prevEnd = Double(whisper_full_get_segment_t1(ctx, prev)) / 100.0
                let curStart = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0

                let hasSilenceBreak = silenceBreaks.contains { breakTime in
                    breakTime >= prevEnd - 0.5 && breakTime <= curStart + 0.5
                }

                if hasSilenceBreak {
                    result = result.trimmingCharacters(in: .whitespaces)
                    result += "\n\n"
                }
            }

            if let cString = whisper_full_get_segment_text(ctx, i) {
                result += String(cString: cString)
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let suppressLogs: Void = {
        whisper_log_set({ _, _, _ in }, nil)
    }()

    private func loadedContext() throws -> OpaquePointer {
        if let context { return context.pointer }
        _ = Self.suppressLogs

        var params = whisper_context_default_params()
        params.use_gpu = true

        if let ctx = whisper_init_from_file_with_params(modelURL.path, params) {
            let wrapped = WhisperContext(pointer: ctx)
            context = wrapped
            return ctx
        }

        params.use_gpu = false
        guard let ctx = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw TranscriberError.modelLoadFailed
        }
        let wrapped = WhisperContext(pointer: ctx)
        context = wrapped
        return ctx
    }
}

