import Foundation
import whisper

struct TranscriptionSettings: Sendable {
    var language: String = "auto"
    var paragraphSplitting: Bool = true
    var silenceThreshold: Double = 1.5
}

struct TranscriptionResult: Sendable {
    let text: String
    let language: String
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

private final class AbortFlag: @unchecked Sendable {
    nonisolated(unsafe) let pointer: UnsafeMutablePointer<Bool>
    nonisolated init() {
        pointer = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        pointer.initialize(to: false)
    }
    deinit { pointer.deinitialize(count: 1); pointer.deallocate() }
}

actor Transcriber {
    let modelURL: URL
    private var context: WhisperContext?
    nonisolated private let abortFlag = AbortFlag()

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    nonisolated func abort() {
        abortFlag.pointer.pointee = true
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
        abortFlag.pointer.pointee = false

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.no_context = true
        params.translate = false
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))

        params.abort_callback = { userData in
            guard let userData else { return false }
            return userData.assumingMemoryBound(to: Bool.self).pointee
        }
        params.abort_callback_user_data = UnsafeMutableRawPointer(abortFlag.pointer)

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
        if abortFlag.pointer.pointee {
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
            let silenceBreaks = detectSilenceBreaks(
                samples: samples,
                sampleRate: 16000,
                minSilenceDuration: settings.silenceThreshold
            )
            text = buildTextWithParagraphs(ctx: ctx, silenceBreaks: silenceBreaks)
        } else {
            text = buildPlainText(ctx: ctx)
        }

        return TranscriptionResult(text: text, language: language)
    }

    func tokenCount(for text: String) throws -> Int {
        let ctx = try loadedContext()
        return Int(whisper_token_count(ctx, text))
    }

    func unload() {
        context = nil
    }

    private func buildPlainText(ctx: OpaquePointer) -> String {
        let n = whisper_full_n_segments(ctx)
        var result = ""
        for i in 0..<n {
            if let cString = whisper_full_get_segment_text(ctx, i) {
                result += String(cString: cString)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectSilenceBreaks(
        samples: [Float],
        sampleRate: Int,
        minSilenceDuration: Double,
        rmsThreshold: Float = 0.01
    ) -> [Double] {
        let windowSize = sampleRate / 20 // 50ms windows
        let minSilenceWindows = Int(minSilenceDuration * 20)
        var breaks: [Double] = []
        var silenceStart: Int?

        for windowIndex in 0..<(samples.count / windowSize) {
            let offset = windowIndex * windowSize
            let end = min(offset + windowSize, samples.count)
            var sumSq: Float = 0
            for i in offset..<end {
                sumSq += samples[i] * samples[i]
            }
            let rms = (sumSq / Float(end - offset)).squareRoot()

            if rms < rmsThreshold {
                if silenceStart == nil { silenceStart = windowIndex }
            } else {
                if let start = silenceStart {
                    let duration = windowIndex - start
                    if duration >= minSilenceWindows {
                        let midWindow = start + duration / 2
                        let timeSeconds = Double(midWindow * windowSize) / Double(sampleRate)
                        breaks.append(timeSeconds)
                    }
                    silenceStart = nil
                }
            }
        }
        return breaks
    }

    private func buildTextWithParagraphs(ctx: OpaquePointer, silenceBreaks: [Double]) -> String {
        let n = whisper_full_n_segments(ctx)
        guard n > 0 else { return "" }

        var result = ""

        for i in 0..<n {
            if i > 0 {
                let prevEnd = Double(whisper_full_get_segment_t1(ctx, i - 1)) / 100.0
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
