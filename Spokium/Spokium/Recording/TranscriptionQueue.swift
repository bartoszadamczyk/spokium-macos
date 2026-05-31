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
        case success(text: String, language: String)
        case failure(RecordingError)
        case cancelled
    }

    private var pendingCount = 0
    private var pendingAudioSeconds: Double = 0
    private var currentStartedAt: ContinuousClock.Instant?
    private var lastTask: Task<Void, Never>?
    private var activeTasks: [Task<Void, Never>] = []
    private var transcriber: Transcriber?

    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    // Read-only accessors for the menu-bar status row.
    var queuedCount: Int { pendingCount }
    var queuedAudioSeconds: Double { pendingAudioSeconds }
    var currentStartTime: ContinuousClock.Instant? { currentStartedAt }

    func enqueue(
        urls: [URL],
        audioSeconds: Double,
        modelURL: URL,
        initialPrompt: String?,
        settings: TranscriptionSettings,
        sessionStartedAt: ContinuousClock.Instant?,
        onComplete: @escaping @MainActor (Outcome) -> Void,
        onIdle: @escaping @MainActor () -> Void
    ) {
        guard !urls.isEmpty else { return }
        pendingCount += 1
        pendingAudioSeconds += audioSeconds
        let previous = lastTask
        let task = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled, let self else {
                for url in urls { try? FileManager.default.removeItem(at: url) }
                return
            }
            await self.run(
                urls: urls,
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
        activeTasks.append(task)
    }

    private func run(
        urls: [URL],
        audioSeconds: Double,
        modelURL: URL,
        initialPrompt: String?,
        settings: TranscriptionSettings,
        sessionStartedAt: ContinuousClock.Instant?,
        onComplete: @MainActor (Outcome) -> Void,
        onIdle: @MainActor () -> Void
    ) async {
        defer {
            for url in urls { try? FileManager.default.removeItem(at: url) }
            pendingCount -= 1
            pendingAudioSeconds = max(0, pendingAudioSeconds - audioSeconds)
            if pendingCount == 0 {
                currentStartedAt = nil
            }
            activeTasks.removeAll { $0.isCancelled }
            if pendingCount == 0 {
                onIdle()
            }
        }

        guard !Task.isCancelled else { return }

        if transcriber?.modelURL != modelURL { transcriber = nil }
        let transcriber = self.transcriber ?? Transcriber(modelURL: modelURL)
        self.transcriber = transcriber

        currentStartedAt = .now

        // Concatenate all segment audio at 16 kHz mono. AudioLoader.loadResampled
        // handles per-segment format differences (e.g. after a mid-session device switch).
        var allSamples: [Float] = []
        var totalAudioSeconds: Double = 0
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
                initialPrompt: initialPrompt,
                settings: settings
            )

            guard !Task.isCancelled else { return }

            let transcriptionDuration = ContinuousClock.now - transcribeStart
            let modelStem = modelURL.deletingPathExtension().lastPathComponent
            logger.info("Transcribed: model=\(modelStem, privacy: .public), language=\(result.language, privacy: .public), chars=\(result.text.count), segments=\(urls.count), audio=\(String(format: "%.1f", totalAudioSeconds))s, recording=\(recordingDuration, privacy: .public), transcription=\(transcriptionDuration, privacy: .public)")

            let (sec, atto) = transcriptionDuration.components
            ModelPerformanceStore.record(
                modelStem: modelStem,
                audioSeconds: totalAudioSeconds,
                transcribeSeconds: Double(sec) + Double(atto) * 1e-18
            )

            onComplete(.success(text: result.text, language: result.language))
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
        for task in activeTasks { task.cancel() }
        activeTasks = []
        lastTask = nil
        pendingCount = 0
        pendingAudioSeconds = 0
        currentStartedAt = nil
    }

    func tokenCount(for text: String, modelURL: URL) async -> Int? {
        if transcriber?.modelURL != modelURL { transcriber = nil }
        let transcriber = self.transcriber ?? Transcriber(modelURL: modelURL)
        self.transcriber = transcriber
        return try? await transcriber.tokenCount(for: text)
    }

    func unload() async {
        await transcriber?.unload()
        transcriber = nil
    }
}
