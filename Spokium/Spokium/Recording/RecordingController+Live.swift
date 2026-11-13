import Foundation
import OSLog

// Live transcription: while recording, the tap streams 16 kHz samples into liveSink.
// A pump drains it every 500 ms into LiveChunker, and each chunk it emits goes onto
// the serial TranscriptionQueue straight away. On stop only the final partial chunk
// is left to transcribe. Results are stitched by LiveTranscriptAssembler.
//
// The recorded segment files are still written: they're kept for the session (debug
// sidecar persistence, future retry) and removed when the session ends.
extension RecordingController {
    func beginLiveSessionIfEnabled() {
        isLiveSession = AppDefaults.liveTranscription
        liveSessionFiles = []
        liveDebugSegments = []
        liveAudioOffset = 0
        liveLanguageCharacters = [:]
        liveLastLanguage = nil
        liveChunker = LiveChunker()
        guard isLiveSession else {
            liveSink = nil
            liveAssembler = nil
            recorder.liveSink = nil
            return
        }
        liveChunker = makeLiveChunker()
        let sink = LiveSampleSink()
        liveSink = sink
        recorder.liveSink = sink
        liveAssembler = LiveTranscriptAssembler(
            paragraphSplitting: AppDefaults.paragraphSplitting,
            paragraphPauseSeconds: AppDefaults.silenceThreshold
        )
    }

    private func makeLiveChunker() -> LiveChunker {
        guard AppDefaults.voiceActivityDetection else {
            logger.info("Live chunking: vad=rms")
            return LiveChunker()
        }
        if sileroClassifier == nil {
            sileroClassifier = SileroSpeechClassifier()
        }
        guard let silero = sileroClassifier else {
            logger.error("Silero VAD failed to load; live chunking falls back to RMS")
            return LiveChunker()
        }
        silero.reset()
        logger.info("Live chunking: vad=silero")
        var config = LiveChunker.Config()
        config.minSpeechSeconds = 0.25
        return LiveChunker(config: config, classifier: silero)
    }

    func startLivePump() {
        guard isLiveSession, livePumpTask == nil else { return }
        livePumpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.drainLiveSamples()
            }
        }
    }

    func stopLivePump() {
        livePumpTask?.cancel()
        livePumpTask = nil
    }

    func drainLiveSamples() {
        guard isLiveSession, let liveSink else { return }
        let samples = liveSink.drain()
        guard !samples.isEmpty else { return }
        for chunk in liveChunker.append(samples) {
            enqueueLiveChunk(chunk)
        }
    }

    // Called from stop() once the recorder has stopped (state is already .finishing).
    func finishLiveRecording(segmentURLs: [URL]) {
        stopLivePump()
        liveSessionFiles.append(contentsOf: segmentURLs)
        drainLiveSamples()
        if let last = liveChunker.flush() {
            enqueueLiveChunk(last)
        } else {
            logger.notice("Live recording stopped: no speech in the final stretch")
        }
        logger.info("Live recording stopped: queued=\(self.queue.queuedCount)")
        if queue.queuedCount == 0 {
            finishSession()
        }
    }

    func endLiveSession(persistDebug: Bool) {
        stopLivePump()
        recorder.liveSink = nil
        liveSink = nil
        liveAssembler = nil
        liveChunker = LiveChunker()
        if persistDebug, AppDefaults.debugMode, !liveSessionFiles.isEmpty {
            DebugRecordingStore.persistAndConsume(liveSessionFiles, metadata: nil, debugSegments: liveDebugSegments)
        } else {
            for url in liveSessionFiles { try? FileManager.default.removeItem(at: url) }
        }
        liveSessionFiles = []
        liveDebugSegments = []
        liveAudioOffset = 0
        liveLanguageCharacters = [:]
        liveLastLanguage = nil
        isLiveSession = false
    }

    static let shortChunkSeconds = 3.0

    private func enqueueLiveChunk(_ chunk: LiveChunker.Chunk) {
        guard let modelURL = ModelManager().selectedModelURL else {
            reportError(.noModel)
            return
        }

        let info = LiveTranscriptAssembler.ChunkInfo(
            duration: chunk.duration,
            leadingOverlap: chunk.leadingOverlap,
            trailingOverlap: chunk.trailingOverlap,
            pauseBefore: chunk.pauseBefore
        )
        let wordTimestamps = chunk.leadingOverlap > 0 || chunk.trailingOverlap > 0
        let isShort = chunk.duration < Self.shortChunkSeconds

        // Debug-sidecar timeline only. Approximate: silence the chunker trimmed between
        // chunks isn't counted.
        let offset = liveAudioOffset
        liveAudioOffset += chunk.duration - chunk.trailingOverlap

        logger.notice("Live chunk queued: \(String(format: "%.1f", chunk.duration), privacy: .public)s, overlap=\(chunk.leadingOverlap)/\(chunk.trailingOverlap), pauseBefore=\(String(format: "%.1f", chunk.pauseBefore), privacy: .public)s, short=\(isShort)")

        queue.enqueue(
            source: .samples(chunk.samples),
            audioSeconds: chunk.duration,
            modelURL: modelURL,
            initialPrompt: { [weak self] in self?.livePrompt() },
            settings: { [weak self] in
                var settings = self?.transcriptionSettings() ?? TranscriptionSettings()
                settings.wordTimestamps = wordTimestamps
                // Too little audio for reliable language ID (often misread as Russian):
                // reuse the previous chunk's language. The first chunk detects freely.
                if isShort, settings.language == "auto", let last = self?.liveLastLanguage {
                    settings.language = last
                }
                // This recording's dominant language wins; otherwise keep the long-term
                // one from LanguageUsageStore that transcriptionSettings() filled in.
                if let self, let sessionDominant = LanguageChooser.dominant(
                    charactersByLanguage: self.liveLanguageCharacters,
                    allowed: settings.allowedLanguages
                ) {
                    settings.fallbackLanguage = sessionDominant
                }
                return settings
            },
            sessionStartedAt: sessionStartedAt,
            onComplete: { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .success(let result):
                    self.liveAssembler?.append(text: result.text, words: result.words, info: info)
                    self.liveLanguageCharacters[result.language, default: 0] += result.text.count
                    if !result.text.isEmpty, result.language != "unknown" {
                        self.liveLastLanguage = result.language
                    }
                    self.logger.info("Live chunk done: chars=\(result.text.count), assembled=\(self.liveAssembler?.text.count ?? -1)")
                    if let segments = result.debugSegments {
                        self.liveDebugSegments += segments.map {
                            DebugSegment(
                                index: Int32(self.liveDebugSegments.count) + $0.index,
                                startSeconds: $0.startSeconds + offset,
                                endSeconds: $0.endSeconds + offset,
                                noSpeechProb: $0.noSpeechProb,
                                text: $0.text
                            )
                        }
                    }
                case .failure(let error):
                    self.reportError(error)
                case .cancelled:
                    break
                }
            },
            onIdle: { [weak self] in
                guard let self else { return }
                self.logger.info("Queue idle: state=\(String(describing: self.state), privacy: .public)")
                // Not during the stop tail: the last words are still being captured and
                // finishLiveRecording() will finish the session itself.
                guard case .finishing = self.state, self.stopTailTask == nil else { return }
                self.finishSession()
            }
        )
    }

    // Dictionary first, previous text last: whisper keeps the *end* of an over-long
    // prompt, and the immediate context matters most for continuity.
    private func livePrompt() -> String? {
        // A flat (lowercase, unpunctuated) tail would teach the next chunk the same style.
        let tail = liveAssembler.map { $0.tail() }.flatMap { PunctuationStyle.isUnpunctuated($0, minWords: 8) ? nil : $0 }
        let parts = [dictionaryPrompt(), tail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
