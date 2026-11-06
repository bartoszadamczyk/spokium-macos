import AVFoundation
import Foundation
import OSLog

// Serial transcription chain. Each enqueue() spawns a Task that awaits the previous
// one, loads the segment audio, runs whisper, and reports the outcome to the caller
// via the supplied closures. Drains are signalled separately via onIdle.
//
// RecordingController owns one instance, and is the only caller. The queue does
// not know about the recording state machine — the controller decides what to do
// with each outcome (append to sessionTexts, paste, etc).
final class TranscriptionQueue {
    enum Outcome {
        case success(TranscriptionResult)
        case failure(RecordingError)
        case cancelled
    }

    enum Source {
        // Recorded segment files, concatenated and transcribed as one unit.
        case files([URL])
        // A live chunk already at 16 kHz mono.
        case samples([Float])

        var urls: [URL] {
            if case .files(let urls) = self { return urls }
            return []
        }
    }

    private var pendingCount = 0
    private var pendingAudioSeconds: Double = 0
    private var currentStartedAt: ContinuousClock.Instant?
    private var lastTask: Task<Void, Never>?
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriber: Transcriber?
    // Bumped by cancelAll(). A run that was already in flight when the queue was
    // cancelled still executes its defer; without this it would decrement the freshly
    // zeroed counters to -1 and the next session would never reach onIdle.
    private var generation = 0

    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    // Read-only accessors for the menu-bar status row.
    var queuedCount: Int { pendingCount }
    var queuedAudioSeconds: Double { pendingAudioSeconds }
    var currentStartTime: ContinuousClock.Instant? { currentStartedAt }

    // `initialPrompt` and `settings` are evaluated when the run starts, not at enqueue
    // time, so a live chunk can use the text and detected language of the chunk
    // transcribed just before it.
    func enqueue(
        source: Source,
        audioSeconds: Double,
        modelURL: URL,
        initialPrompt: @escaping @MainActor () -> String?,
        settings: @escaping @MainActor () -> TranscriptionSettings,
        sessionStartedAt: ContinuousClock.Instant?,
        onComplete: @escaping @MainActor (Outcome) -> Void,
        onIdle: @escaping @MainActor () -> Void
    ) {
        if case .files(let urls) = source, urls.isEmpty { return }
        let urls = source.urls
        pendingCount += 1
        pendingAudioSeconds += audioSeconds
        let previous = lastTask
        let id = UUID()
        let enqueuedGeneration = generation
        let task = Task { [weak self] in
            defer { self?.activeTasks[id] = nil }
            _ = await previous?.value
            guard !Task.isCancelled, let self else {
                for url in urls { try? FileManager.default.removeItem(at: url) }
                return
            }
            await self.run(
                generation: enqueuedGeneration,
                source: source,
                audioSeconds: audioSeconds,
                modelURL: modelURL,
                initialPrompt: initialPrompt,
                settings: settings,
                sessionStartedAt: sessionStartedAt,
                onComplete: onComplete,
                onIdle: onIdle
            )
        }
        lastTask = task
        activeTasks[id] = task
    }

    private func run(
        generation runGeneration: Int,
        source: Source,
        audioSeconds: Double,
        modelURL: URL,
        initialPrompt: @MainActor () -> String?,
        settings: @MainActor () -> TranscriptionSettings,
        sessionStartedAt: ContinuousClock.Instant?,
        onComplete: @MainActor (Outcome) -> Void,
        onIdle: @MainActor () -> Void
    ) async {
        let urls = source.urls
        var capturedDebugSegments: [DebugSegment]?
        var capturedMetadata: DebugMetadata?
        defer {
            if AppDefaults.debugMode {
                DebugRecordingStore.persistAndConsume(
                    urls,
                    metadata: capturedMetadata,
                    debugSegments: capturedDebugSegments
                )
            } else {
                for url in urls { try? FileManager.default.removeItem(at: url) }
            }
            if runGeneration == generation {
                pendingCount = max(0, pendingCount - 1)
                pendingAudioSeconds = max(0, pendingAudioSeconds - audioSeconds)
                if pendingCount == 0 {
                    currentStartedAt = nil
                    onIdle()
                }
            }
        }

        guard !Task.isCancelled else { return }

        if transcriber?.modelURL != modelURL { transcriber = nil }
        let transcriber = self.transcriber ?? Transcriber(modelURL: modelURL)
        self.transcriber = transcriber
        let abortToken = transcriber.abortToken()

        currentStartedAt = .now

        // Concatenate all segment audio at 16 kHz mono. AudioLoader.loadResampled
        // handles per-segment format differences (e.g. after a mid-session device switch).
        var allSamples: [Float] = []
        var totalAudioSeconds: Double = 0
        if case .samples(let samples) = source {
            allSamples = samples
            totalAudioSeconds = Double(samples.count) / 16_000
        }
        for url in urls {
            guard !Task.isCancelled else { return }
            do {
                if let audioFile = try? AVAudioFile(forReading: url) {
                    totalAudioSeconds += Double(audioFile.length) / audioFile.processingFormat.sampleRate
                }
                let samples = try AudioLoader.loadResampled(url: url)
                allSamples.append(contentsOf: samples)
            } catch {
                logger.warning("Failed to load segment \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 16 kHz × 0.5 s = 8 000 samples minimum
        guard allSamples.count >= 8_000 else {
            logger.info("Skipping recording too short for speech (\(String(format: "%.2f", totalAudioSeconds))s total)")
            return
        }

        let transcribeStart = ContinuousClock.now
        let recordingDuration = sessionStartedAt.map { ContinuousClock.now - $0 } ?? .zero

        do {
            let result = try await transcriber.transcribe(
                samples: allSamples,
                initialPrompt: initialPrompt(),
                settings: settings(),
                abortToken: abortToken
            )

            guard !Task.isCancelled else { return }

            capturedDebugSegments = result.debugSegments
            let transcriptionDuration = ContinuousClock.now - transcribeStart
            let modelStem = modelURL.deletingPathExtension().lastPathComponent
            logger.info("Transcribed: model=\(modelStem, privacy: .public), language=\(result.language, privacy: .public), chars=\(result.text.count), source=\(urls.isEmpty ? "live-chunk" : "\(urls.count) file(s)", privacy: .public), audio=\(String(format: "%.1f", totalAudioSeconds))s, recording=\(recordingDuration, privacy: .public), transcription=\(transcriptionDuration, privacy: .public)")

            let (tsec, tatto) = transcriptionDuration.components
            let transcribeSeconds = Double(tsec) + Double(tatto) * 1e-18
            LanguageUsageStore.record(language: result.language, characters: result.text.count)
            ModelPerformanceStore.record(
                modelStem: modelStem,
                audioSeconds: totalAudioSeconds,
                transcribeSeconds: transcribeSeconds
            )

            let (rsec, ratto) = recordingDuration.components
            let recordingSecondsDouble = Double(rsec) + Double(ratto) * 1e-18
            capturedMetadata = DebugMetadata(
                modelStem: modelStem,
                language: result.language,
                charCount: result.text.count,
                totalAudioSeconds: totalAudioSeconds,
                recordingSeconds: recordingSecondsDouble,
                transcriptionSeconds: transcribeSeconds
            )

            onComplete(.success(result))
        } catch TranscriberError.cancelled {
            logger.info("Transcription aborted")
            onComplete(.cancelled)
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            onComplete(.failure(.transcriptionFailed(error.localizedDescription)))
        }
    }

    // Signals whisper to abort between graph computations. Safe to call at any time;
    // an unload() that follows will serialise after the in-flight transcribe() exits.
    func abort() {
        transcriber?.abort()
    }

    // Tears down all queue state. Used for cancel-all and as part of cleanup().
    func cancelAll() {
        transcriber?.abort()
        for task in activeTasks.values { task.cancel() }
        activeTasks = [:]
        generation += 1
        lastTask = nil
        pendingCount = 0
        pendingAudioSeconds = 0
        currentStartedAt = nil
    }

    func tokenCount(for text: String, modelURL: URL) async -> Int? {
        if let transcriber, transcriber.modelURL == modelURL {
            return try? await transcriber.tokenCount(for: text)
        }
        // Don't swap out the shared transcriber while a run is using it — abort() and
        // unload() would then target the wrong instance. Use a throwaway one instead.
        let fresh = Transcriber(modelURL: modelURL)
        if pendingCount == 0 { self.transcriber = fresh }
        return try? await fresh.tokenCount(for: text)
    }

    func unload() async {
        await transcriber?.unload()
        transcriber = nil
    }
}
