import Foundation
import OSLog
import Synchronization
import whisper

nonisolated private let transcriberLogger = Logger(subsystem: "com.spokium.mac", category: "Transcriber")

struct TranscriptionSettings: Sendable {
    var language: String = "auto"
    // With language "auto": the languages the user speaks (e.g. ["pl", "en"]). Auto
    // results outside this list are re-run with a forced fallback. Empty = accept any.
    var allowedLanguages: [String] = []
    // Preferred fallback for the above, e.g. the dominant language of the session so far.
    var fallbackLanguage: String?
    var paragraphSplitting: Bool = true
    var minSilenceDuration: Double = AppDefaults.silenceThresholdDefault
    // Per-token timing, needed by LiveTranscriptAssembler to de-duplicate overlapped
    // chunk seams. Off by default since it costs a little extra decode time.
    var wordTimestamps: Bool = false
}

struct TranscriptionResult: Sendable {
    let text: String
    let language: String
    // Per-segment whisper output, populated only when AppDefaults.debugMode is on.
    // Consumers (TranscriptionQueue) write this alongside the audio file as a
    // sidecar markdown log so debug data lives in one place on disk.
    let debugSegments: [DebugSegment]?
    // Populated only when TranscriptionSettings.wordTimestamps is set.
    var words: [TimedWord] = []
    // Whisper's own time for this call, excluding the model load. 0 when whisper was
    // skipped (no speech), so callers don't count it in speed stats.
    var inferenceSeconds: Double = 0
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

enum TranscriberError: LocalizedError {
    case modelLoadFailed
    case inferenceFailed(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            "The Whisper model couldn't be loaded. It may be damaged — try deleting and downloading it again in Settings → Model."
        case .inferenceFailed(let code):
            "Whisper failed to transcribe the audio (error \(code))."
        case .cancelled:
            "Transcription was cancelled."
        }
    }
}

private final class WhisperContext: @unchecked Sendable {
    nonisolated(unsafe) let pointer: OpaquePointer
    nonisolated init(pointer: OpaquePointer) { self.pointer = pointer }
    deinit { whisper_free(pointer) }
}

// abort() bumps `epoch`; each whisper run is armed with the epoch its caller captured
// before loading audio. Comparing the two (rather than resetting a Bool at run start)
// means an abort that lands before the run begins is never lost, and a new run can't
// un-abort one that's still in flight.
private nonisolated final class LoadState: Sendable {
    private let loaded = Atomic<Bool>(false)
    var isLoaded: Bool { loaded.load(ordering: .acquiring) }
    func markLoaded() { loaded.store(true, ordering: .releasing) }
    func markUnloaded() { loaded.store(false, ordering: .releasing) }
}

private nonisolated final class AbortFlag: Sendable {
    let epoch = Atomic<Int>(0)
    let armed = Atomic<Int>(0)
    var isAborted: Bool { epoch.load(ordering: .relaxed) != armed.load(ordering: .relaxed) }
}

actor Transcriber {
    let modelURL: URL
    private var context: WhisperContext?
    nonisolated private let abortFlag = AbortFlag()
    private var vad: SileroSpeechClassifier?
    private var vadUnavailable = false
    // Silero flags for the samples of the call in progress; lets segment filtering see
    // how much speech each segment's time range actually contained.
    private var currentSpeechFlags: [Bool]?

    // whisper.cpp only looks for the Core ML encoder when the context is created, so a
    // transcriber built before the encoder was installed (or removed) is stale.
    nonisolated let usesCoreMLEncoder: Bool
    // Loads the model without its Core ML encoder even if one is installed: used while
    // the Neural Engine is still compiling, and for encoders marked unusable.
    nonisolated let gpuOnly: Bool
    nonisolated private let loadState = LoadState()

    nonisolated var isStale: Bool {
        let encoderInstalled = FileManager.default.fileExists(atPath: WhisperModel.coreMLURL(forModelAt: modelURL).path)
        return gpuOnly ? false : encoderInstalled != usesCoreMLEncoder
    }

    nonisolated var isLoaded: Bool { loadState.isLoaded }

    init(modelURL: URL, gpuOnly: Bool = false) {
        self.modelURL = modelURL
        self.gpuOnly = gpuOnly
        self.usesCoreMLEncoder = !gpuOnly
            && FileManager.default.fileExists(atPath: WhisperModel.coreMLURL(forModelAt: modelURL).path)
    }

    // whisper.cpp derives the encoder path from the model path string, so the same .bin
    // opened through a link in a folder without an encoder loads GPU-only.
    private static func gpuOnlyPath(for modelURL: URL) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gpu-only", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent(modelURL.lastPathComponent)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != modelURL.path {
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: modelURL)
        }
        return link.path
    }

    nonisolated func abort() {
        abortFlag.epoch.add(1, ordering: .relaxed)
    }

    nonisolated func abortToken() -> Int {
        abortFlag.epoch.load(ordering: .relaxed)
    }

    func transcribe(
        audioURL: URL,
        initialPrompt: String? = nil,
        settings: TranscriptionSettings = TranscriptionSettings()
    ) throws -> TranscriptionResult {
        let token = abortToken()
        let samples = try AudioLoader.loadResampled(url: audioURL)
        return try transcribe(samples: samples, initialPrompt: initialPrompt, settings: settings, abortToken: token)
    }

    func transcribe(
        samples: [Float],
        initialPrompt: String? = nil,
        settings: TranscriptionSettings = TranscriptionSettings(),
        abortToken: Int? = nil
    ) throws -> TranscriptionResult {
        abortFlag.armed.store(abortToken ?? self.abortToken(), ordering: .relaxed)
        if abortFlag.isAborted { throw TranscriberError.cancelled }

        let speech = speechFlags(for: samples)
        currentSpeechFlags = speech
        defer { currentSpeechFlags = nil }
        // True silence only: no classified speech *and* nothing audible. Silero alone
        // isn't trusted to drop audio — it scores real whispering as non-speech.
        if let speech, Double(speech.filter { $0 }.count) * Self.vadWindowSeconds < Self.minSpeechSeconds,
           !Self.isAudible(samples) {
            transcriberLogger.notice("No speech per VAD in \(String(format: "%.1f", Double(samples.count) / 16_000), privacy: .public)s — skipping whisper")
            return TranscriptionResult(text: "", language: "unknown", debugSegments: nil)
        }

        let ctx = try loadedContext()
        let inferenceStart = ContinuousClock.now

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.no_context = true
        params.translate = false
        params.token_timestamps = settings.wordTimestamps
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))

        params.abort_callback = { userData in
            guard let userData else { return false }
            let flag = Unmanaged<AbortFlag>.fromOpaque(userData).takeUnretainedValue()
            return flag.isAborted
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abortFlag).toOpaque()

        // "auto" is passed through unforced: the decoder can then keep mixed-language
        // speech in both languages. Forcing a language makes it translate the rest.
        var langPtr: UnsafeMutablePointer<CChar>? = settings.language == "auto" ? nil : strdup(settings.language)
        params.language = UnsafePointer(langPtr)
        defer { free(langPtr) }

        var promptPtr = initialPrompt.flatMap { strdup($0) }
        defer { free(promptPtr) }
        params.initial_prompt = UnsafePointer(promptPtr)

        try runWhisper(ctx: ctx, samples: samples, params: &params)

        // Defensive fallback: only when auto-detect lands on a language the user doesn't
        // speak (typically a short or quiet chunk tagged as e.g. Turkish) do we re-run
        // with a forced language — the session's dominant one if known, otherwise the
        // most probable language from the user's list.
        if settings.language == "auto", !settings.allowedLanguages.isEmpty {
            let detected = whisper_lang_str(whisper_full_lang_id(ctx)).map { String(cString: $0) } ?? "unknown"
            if !settings.allowedLanguages.contains(detected) {
                let fallback = settings.fallbackLanguage.flatMap { settings.allowedLanguages.contains($0) ? $0 : nil }
                    ?? restrictedDetection(ctx: ctx, samples: samples, allowed: settings.allowedLanguages, threads: params.n_threads)
                if let fallback {
                    transcriberLogger.info("Auto-detected \(detected, privacy: .public) is outside \(settings.allowedLanguages.joined(separator: ","), privacy: .public); re-running as \(fallback, privacy: .public)")
                    free(langPtr)
                    langPtr = strdup(fallback)
                    params.language = UnsafePointer(langPtr)
                    try runWhisper(ctx: ctx, samples: samples, params: &params)
                }
            }
        }

        // Loop hallucination guard: greedy sampling occasionally gets stuck
        // emitting the same segment over and over. Retry once at temperature
        // 0.4 — whisper.cpp's recommended fallback — and if it *still* loops,
        // surface no text so the caller hits the .empty completion feedback
        // rather than pasting a wall of repetition over the user's clipboard.
        // A phrase repeated inside one segment also triggers the retry, but if it
        // persists we keep the retry's text — it's usually mostly right, unlike the
        // segment-level loop which tends to replace real speech wholesale.
        var loopFallbackTriggered = false
        var collapsePhraseLoop = false
        let segmentLoop = LoopDetector.hasLoop(segmentTexts: keptSegmentTexts(ctx: ctx))
        if segmentLoop || LoopDetector.hasRepeatedPhrase(keptSegmentTexts(ctx: ctx).joined(separator: " ")) {
            transcriberLogger.warning("Loop hallucination detected (segmentLoop=\(segmentLoop)); retrying at temperature 0.4")
            params.temperature = 0.4
            try runWhisper(ctx: ctx, samples: samples, params: &params)
            if LoopDetector.hasLoop(segmentTexts: keptSegmentTexts(ctx: ctx)) {
                transcriberLogger.warning("Loop hallucination persisted after retry; dropping output")
                loopFallbackTriggered = true
            } else if LoopDetector.hasRepeatedPhrase(keptSegmentTexts(ctx: ctx).joined(separator: " ")) {
                // The rest is usually right; only the repetition is noise.
                transcriberLogger.warning("Repeated phrase persisted after retry; collapsing it")
                collapsePhraseLoop = true
            }
        }

        // Flat output (all lowercase, no punctuation): re-run once with a punctuated
        // example sentence at the end of the prompt. The retry's text is kept even if
        // it's still flat — it's no worse.
        if !loopFallbackTriggered,
           PunctuationStyle.isUnpunctuated(keptSegmentTexts(ctx: ctx).joined(separator: " ")) {
            let detected = whisper_lang_str(whisper_full_lang_id(ctx)).map { String(cString: $0) } ?? "unknown"
            if let retryPrompt = PunctuationStyle.retryPrompt(original: initialPrompt, language: detected) {
                transcriberLogger.notice("Unpunctuated lowercase output (\(detected, privacy: .public)); retrying with a punctuated prompt")
                free(promptPtr)
                promptPtr = strdup(retryPrompt)
                params.initial_prompt = UnsafePointer(promptPtr)
                try runWhisper(ctx: ctx, samples: samples, params: &params)
            }
        }

        let langId = whisper_full_lang_id(ctx)
        let language: String
        if let cStr = whisper_lang_str(langId) {
            language = String(cString: cStr)
        } else {
            language = "unknown"
        }

        var text: String
        if loopFallbackTriggered {
            text = ""
        } else if settings.paragraphSplitting {
            // A pause is not speech *and* not audible — whispering scores as non-speech.
            let silenceBreaks = speech.map { flags in
                SilenceDetector.breaks(
                    speech: zip(flags, Self.audibleFlags(samples)).map { $0 || $1 },
                    windowSeconds: Self.vadWindowSeconds,
                    minSilenceDuration: settings.minSilenceDuration
                )
            } ?? SilenceDetector.breaks(
                samples: samples,
                sampleRate: 16000,
                minSilenceDuration: settings.minSilenceDuration
            )
            text = buildTextWithParagraphs(ctx: ctx, silenceBreaks: silenceBreaks)
        } else {
            text = buildPlainText(ctx: ctx)
        }

        if collapsePhraseLoop { text = LoopDetector.collapseRepeats(text) }

        let debugSegments: [DebugSegment]? = AppDefaults.debugMode ? collectDebugSegments(ctx: ctx) : nil

        var result = TranscriptionResult(text: text, language: language, debugSegments: debugSegments)
        if settings.wordTimestamps, !loopFallbackTriggered {
            result.words = collectWords(ctx: ctx)
        }
        let (secs, attos) = (ContinuousClock.now - inferenceStart).components
        result.inferenceSeconds = Double(secs) + Double(attos) * 1e-18
        return result
    }

    // Groups tokens into words by their leading space. Token text is accumulated as raw
    // bytes because whisper can split a multi-byte UTF-8 character (e.g. Polish "ł")
    // across tokens, and decoding each token on its own would corrupt it.
    private func collectWords(ctx: OpaquePointer) -> [TimedWord] {
        let eot = whisper_token_eot(ctx)
        var words: [TimedWord] = []
        var bytes: [UInt8] = []
        var start: Double = 0

        func flush() {
            guard !bytes.isEmpty else { return }
            words.append(TimedWord(text: String(decoding: bytes, as: UTF8.self), start: start))
            bytes = []
        }

        for i in keptSegmentIndices(ctx: ctx) {
            for j in 0..<whisper_full_n_tokens(ctx, i) {
                guard whisper_full_get_token_id(ctx, i, j) < eot,
                      let cText = whisper_full_get_token_text(ctx, i, j)
                else { continue }
                let tokenBytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(cText).assumingMemoryBound(to: UInt8.self), count: strlen(cText)))
                guard !tokenBytes.isEmpty else { continue }
                if tokenBytes.first == UInt8(ascii: " ") || bytes.isEmpty {
                    flush()
                    start = Double(whisper_full_get_token_t0(ctx, i, j)) / 100.0
                }
                bytes.append(contentsOf: tokenBytes)
            }
        }
        flush()
        return words
    }

    // Scores all languages and returns the most probable one from `allowed`, or nil if
    // detection fails. Costs one extra encoder pass, so it's only used as a fallback.
    private func restrictedDetection(ctx: OpaquePointer, samples: [Float], allowed: [String], threads: Int32) -> String? {
        guard !allowed.isEmpty else { return nil }
        if allowed.count == 1 { return allowed[0] }

        let melStatus = samples.withUnsafeBufferPointer {
            whisper_pcm_to_mel(ctx, $0.baseAddress, Int32(samples.count), threads)
        }
        guard melStatus == 0 else { return nil }

        var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard whisper_lang_auto_detect(ctx, 0, threads, &probs) >= 0 else { return nil }

        var byCode: [String: Float] = [:]
        for code in allowed {
            let id = Int(whisper_lang_id(code))
            if id >= 0, id < probs.count { byCode[code] = probs[id] }
        }
        let chosen = LanguageChooser.best(probabilities: byCode, allowed: allowed)
        transcriberLogger.info("Restricted language detection: \(chosen ?? "none", privacy: .public) among \(allowed.joined(separator: ","), privacy: .public)")
        return chosen
    }

    private func runWhisper(ctx: OpaquePointer, samples: [Float], params: inout whisper_full_params) throws {
        let status = samples.withUnsafeBufferPointer { ptr in
            whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
        }
        if abortFlag.isAborted {
            throw TranscriberError.cancelled
        }
        guard status == 0 else { throw TranscriberError.inferenceFailed(status) }
    }

    private func keptSegmentTexts(ctx: OpaquePointer) -> [String] {
        keptSegmentIndices(ctx: ctx).map { i in
            guard let cString = whisper_full_get_segment_text(ctx, i) else { return "" }
            return String(cString: cString)
        }
    }

    func tokenCount(for text: String) throws -> Int {
        let ctx = try loadedContext()
        return Int(whisper_token_count(ctx, text))
    }

    // Loads the model ahead of the first transcription (e.g. while the user is still
    // speaking). The actor serialises this with transcribe(), so a chunk that arrives
    // mid-load simply waits for it instead of loading a second copy.
    func warmUp() {
        _ = try? loadedContext()
    }

    func unload() {
        context = nil
        loadState.markUnloaded()
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

    private func keptSegmentIndices(ctx: OpaquePointer) -> [Int32] {
        let n = whisper_full_n_segments(ctx)
        return (0..<n).filter { i in
            let noSpeech = whisper_full_get_segment_no_speech_prob(ctx, i)
            let logProb = averageLogProb(ctx: ctx, segment: i)
            let drop = NoSpeechFilter.shouldDrop(noSpeechProb: noSpeech, averageLogProb: logProb)
            if drop {
                // Metadata only. Kept at notice level so a dropped quiet phrase is traceable.
                transcriberLogger.notice("No-speech filter dropped segment \(i): no_speech=\(String(format: "%.2f", noSpeech), privacy: .public) avg_logprob=\(String(format: "%.2f", logProb ?? .nan), privacy: .public)")
                return false
            }
            if let flags = currentSpeechFlags, let cText = whisper_full_get_segment_text(ctx, i) {
                let t0 = Double(whisper_full_get_segment_t0(ctx, i)) / 100
                let t1 = Double(whisper_full_get_segment_t1(ctx, i)) / 100
                let ratio = HallucinationFilter.speechRatio(flags: flags, windowSeconds: Self.vadWindowSeconds, from: t0, to: t1)
                if HallucinationFilter.shouldDrop(text: String(cString: cText), speechRatio: ratio) {
                    transcriberLogger.notice("Stock-phrase filter dropped segment \(i): speech=\(String(format: "%.0f%%", ratio * 100), privacy: .public)")
                    return false
                }
            }
            return true
        }
    }

    private func averageLogProb(ctx: OpaquePointer, segment: Int32) -> Float? {
        let eot = whisper_token_eot(ctx)
        var sum: Float = 0
        var count = 0
        for j in 0..<whisper_full_n_tokens(ctx, segment) {
            guard whisper_full_get_token_id(ctx, segment, j) < eot else { continue }
            let p = whisper_full_get_token_p(ctx, segment, j)
            guard p > 0 else { continue }
            sum += log(p)
            count += 1
        }
        return count > 0 ? sum / Float(count) : nil
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

    private static func audibleFlags(_ samples: [Float]) -> [Bool] {
        let usable = samples.count / 512 * 512
        return RMSSpeechClassifier(windowSamples: 512, silenceRMS: RMSSpeechClassifier.audibleRMS).classify(samples[0..<usable])
    }

    private static func isAudible(_ samples: [Float]) -> Bool {
        audibleFlags(samples).contains(true)
    }

    private static let vadWindowSeconds = 512.0 / 16_000
    private static let minSpeechSeconds = 0.25

    // Per-window Silero flags, or nil when VAD is switched off or failed to load
    // (callers then fall back to RMS).
    private func speechFlags(for samples: [Float]) -> [Bool]? {
        guard AppDefaults.voiceActivityDetection, !vadUnavailable else { return nil }
        if vad == nil {
            vad = SileroSpeechClassifier()
            vadUnavailable = vad == nil
        }
        guard let vad else { return nil }
        vad.reset()
        let usable = samples.count / vad.windowSamples * vad.windowSamples
        return vad.classify(samples[0..<usable])
    }

    private static let suppressLogs: Void = {
        whisper_log_set({ _, _, _ in }, nil)
    }()

    // The VAD logs through the same callback, several lines per call.
    nonisolated static func suppressWhisperLogs() {
        _ = suppressLogs
    }

    private func loadedContext() throws -> OpaquePointer {
        if let context { return context.pointer }
        _ = Self.suppressLogs
        let loadStart = ContinuousClock.now
        defer {
            transcriberLogger.notice("Model loaded: \(self.modelURL.deletingPathExtension().lastPathComponent, privacy: .public) in \(ContinuousClock.now - loadStart, privacy: .public), coreML=\(self.usesCoreMLEncoder), gpuOnly=\(self.gpuOnly)")
        }

        let path = gpuOnly ? try Self.gpuOnlyPath(for: modelURL) : modelURL.path
        var params = whisper_context_default_params()
        params.use_gpu = true

        if let ctx = whisper_init_from_file_with_params(path, params) {
            let wrapped = WhisperContext(pointer: ctx)
            context = wrapped
            loadState.markLoaded()
            return ctx
        }

        params.use_gpu = false
        guard let ctx = whisper_init_from_file_with_params(path, params) else {
            throw TranscriberError.modelLoadFailed
        }
        let wrapped = WhisperContext(pointer: ctx)
        context = wrapped
        loadState.markLoaded()
        return ctx
    }
}

