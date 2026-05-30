import AppKit
import AVFoundation
import Foundation
import KeyboardShortcuts
import OSLog

@Observable
@MainActor
final class RecordingController {
    var state: RecordingState = .idle
    var lastError: RecordingError?
    var persistentError: RecordingError?
    var lastCompletion: CompletionFeedback?
    var inputLevel: Float = 0

    // Read-only queue/status accessors for the menu bar. Intentionally derived
    // from durations and counts only — never expose transcript content.
    var recordingAudioSeconds: Double {
        var total = pendingSegmentsAudioSeconds
        if let start = currentSegmentStartedAt, state == .recording {
            total += Self.seconds(of: ContinuousClock.now - start)
        }
        return total
    }

    var queuedTranscriptionCount: Int {
        pendingTranscriptionCount
    }

    // Estimated remaining transcription time for everything currently in the queue,
    // based on the selected model's historical realtime speed. Returns nil when no
    // stats are available yet (first run on this model).
    var transcriptionEstimateSeconds: Double? {
        guard pendingTranscriptionAudioSeconds > 0 else { return nil }
        let manager = ModelManager()
        guard let url = manager.selectedModelURL else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard let stats = ModelPerformanceStore.read(modelStem: stem),
              stats.speedRatio > 0
        else { return nil }

        var estimate = pendingTranscriptionAudioSeconds / stats.speedRatio
        if let start = currentTranscriptionStartedAt {
            estimate -= Self.seconds(of: ContinuousClock.now - start)
        }
        return max(0, estimate)
    }

    static func seconds(of duration: Duration) -> Double {
        let (sec, atto) = duration.components
        return Double(sec) + Double(atto) * 1e-18
    }

    // State shared with extensions in this folder. Kept internal (not private) so
    // RecordingController+Segments / +Transcription / +Monitors can read and mutate it.
    let recorder = AudioRecorder()
    let logger = Logger(subsystem: "com.spokium.mac", category: "Recording")
    var transcriber: Transcriber?
    var sessionStartedAt: ContinuousClock.Instant?
    var activeTasks: [Task<Void, Never>] = []
    var lastTranscriptionTask: Task<Void, Never>?  // tail of the serial chain
    var levelTimer: Timer?
    var escapeMonitor: Any?
    var autoStopTask: Task<Void, Never>?
    var splitTimer: Timer?
    var currentRecordingURL: URL?
    var pendingAudioSegments: [URL] = []  // accumulated split segments, transcribed as one unit on stop
    var pendingStartCancel = false
    var isResumingAfterSplit = false

    // Session: one or more consecutive recordings whose results are concatenated
    var sessionTexts: [String] = []
    var pendingTranscriptionCount = 0

    // Audio-duration accounting for the menu bar status row.
    var currentSegmentStartedAt: ContinuousClock.Instant?
    var pendingSegmentsAudioSeconds: Double = 0  // split segments not yet enqueued
    var pendingTranscriptionAudioSeconds: Double = 0  // queued + in-progress
    var currentTranscriptionStartedAt: ContinuousClock.Instant?

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.handleKeyDown()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.handleKeyUp()
        }
        recorder.onConfigurationChange = { [weak self] in
            self?.handleAudioConfigurationChange()
        }
    }

    private var isPushToRecord: Bool {
        UserDefaults.standard.bool(forKey: "pushToRecord")
    }

    private func handleKeyDown() {
        if isPushToRecord {
            switch state {
            case .idle:
                state = .starting
                Task { await start() }
            case .finishing:
                continueSession()
            default:
                break
            }
        } else {
            toggle()
        }
    }

    private func handleKeyUp() {
        guard isPushToRecord else { return }
        if case .recording = state {
            stop()
        }
    }

    func cleanup() async {
        // Halt whisper between graph computations. unload() below serialises after
        // the in-flight transcribe() exits, so it sees the freed-context state.
        transcriber?.abort()

        if recorder.isRunning {
            _ = recorder.stop()
            clearCurrentSegment()
        }

        stopLevelMonitoring()
        stopSplitTimer()
        stopEscapeMonitor()
        autoStopTask?.cancel()
        autoStopTask = nil

        for url in pendingAudioSegments { try? FileManager.default.removeItem(at: url) }
        pendingAudioSegments = []

        for task in activeTasks { task.cancel() }
        activeTasks = []

        await transcriber?.unload()
        transcriber = nil
    }

    func dismissError() {
        lastError = nil
    }

    func dismissPersistentError() {
        persistentError = nil
    }

    func clearCompletion() {
        lastCompletion = nil
    }

    func reportError(_ error: RecordingError) {
        lastError = error
        persistentError = error
    }

    func countDictionaryTokens(_ text: String) async -> Int? {
        let manager = ModelManager()
        guard let modelURL = manager.selectedModelURL else { return nil }
        if transcriber?.modelURL != modelURL {
            transcriber = nil
        }
        let transcriber = self.transcriber ?? Transcriber(modelURL: modelURL)
        self.transcriber = transcriber
        return try? await transcriber.tokenCount(for: text)
    }

    func toggle() {
        switch state {
        case .idle:
            state = .starting
            Task { await start() }
        case .starting:
            break
        case .recording:
            stop()
        case .finishing:
            // Keep transcription running in background; start another recording
            continueSession()
        }
    }

    func cancel() {
        switch state {
        case .starting:
            pendingStartCancel = true
            logger.info("Recording start cancellation requested")
        case .recording:
            stopLevelMonitoring()
            stopSplitTimer()
            stopEscapeMonitor()
            autoStopTask?.cancel()
            autoStopTask = nil
            _ = recorder.stop()
            clearCurrentSegment()
            cancelAllPending()
            logger.info("Recording cancelled")
        case .finishing:
            cancelAllPending()
            logger.info("Transcription cancelled")
        case .idle:
            break
        }
    }

    func cancelAllPending() {
        transcriber?.abort()
        for task in activeTasks { task.cancel() }
        activeTasks = []
        lastTranscriptionTask = nil
        sessionTexts = []
        pendingTranscriptionCount = 0
        pendingTranscriptionAudioSeconds = 0
        pendingSegmentsAudioSeconds = 0
        currentSegmentStartedAt = nil
        currentTranscriptionStartedAt = nil
        for url in pendingAudioSegments { try? FileManager.default.removeItem(at: url) }
        pendingAudioSegments = []
        state = .idle
        stopEscapeMonitor()
    }

    // Transitions out of recording; goes to .finishing if transcriptions are pending, else .idle
    func returnFromRecording() {
        if pendingTranscriptionCount > 0 {
            state = .finishing
        } else {
            state = .idle
            stopEscapeMonitor()
        }
    }

    func clearCurrentSegment() {
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
        }
    }

    func audioDuration(at url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func makeTempURL() -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(timestamp).caf")
    }
}
