import Foundation
import whisper

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

    func transcribe(audioURL: URL) throws -> TranscriptionResult {
        let samples = try AudioLoader.loadResampled(url: audioURL)
        return try transcribe(samples: samples)
    }

    func transcribe(samples: [Float]) throws -> TranscriptionResult {
        let ctx = try loadedContext()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.no_context = true
        params.translate = false
        params.language = nil
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))

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

        let n = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<n {
            if let cString = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cString)
            }
        }
        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language
        )
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
