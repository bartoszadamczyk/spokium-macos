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
}

private final class WhisperContext: @unchecked Sendable {
    nonisolated(unsafe) let pointer: OpaquePointer
    nonisolated init(pointer: OpaquePointer) { self.pointer = pointer }
    deinit { whisper_free(pointer) }
}

actor Transcriber {
    let modelURL: URL
    private var context: WhisperContext?

    init(modelURL: URL) {
        self.modelURL = modelURL
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

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.no_context = true
        params.translate = false
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))

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
            let thresholdCs = Int64(settings.silenceThreshold * 100)
            text = buildTextWithParagraphs(ctx: ctx, thresholdCs: thresholdCs)
        } else {
            text = buildPlainText(ctx: ctx)
        }

        return TranscriptionResult(text: text, language: language)
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

    private func buildTextWithParagraphs(ctx: OpaquePointer, thresholdCs: Int64) -> String {
        let n = whisper_full_n_segments(ctx)
        guard n > 0 else { return "" }

        var result = ""
        var previousEnd: Int64 = 0

        for i in 0..<n {
            let t0 = whisper_full_get_segment_t0(ctx, i)

            if i > 0 && (t0 - previousEnd) >= thresholdCs {
                result = result.trimmingCharacters(in: .whitespaces)
                result += "\n\n"
            }

            if let cString = whisper_full_get_segment_text(ctx, i) {
                result += String(cString: cString)
            }

            previousEnd = whisper_full_get_segment_t1(ctx, i)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadedContext() throws -> OpaquePointer {
        if let context { return context.pointer }

        var params = whisper_context_default_params()
        params.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw TranscriberError.modelLoadFailed
        }
        let wrapped = WhisperContext(pointer: ctx)
        context = wrapped
        return ctx
    }
}
