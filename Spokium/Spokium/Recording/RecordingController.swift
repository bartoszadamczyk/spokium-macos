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
        queue.queuedCount
    }

    // Estimated remaining transcription time for everything currently in the queue,
    // based on the selected model's historical realtime speed. Returns nil when no
    // stats are available yet (first run on this model).
    var transcriptionEstimateSeconds: Double? {
        guard queue.queuedAudioSeconds > 0 else { return nil }
        let manager = ModelManager()
        guard let url = manager.selectedModelURL else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard let stats = ModelPerformanceStore.read(modelStem: stem),
              stats.speedRatio > 0
        else { return nil }

        var estimate = queue.queuedAudioSeconds / stats.speedRatio
        if let start = queue.currentStartTime {
            estimate -= Self.seconds(of: ContinuousClock.now - start)
        }
        return max(0, estimate)
    }

    static func seconds(of duration: Duration) -> Double {
        let (sec, atto) = duration.components
        return Double(sec) + Double(atto) * 1e-18
    }

    // State shared with extensions in this folder. Kept internal (not private) so
    // RecordingController+Segments / +Transcription can read and mutate it.
    let recorder = AudioRecorder()
    let logger = Logger(subsystem: "com.spokium.mac", category: "Recording")
    let monitors = RecordingMonitors()
    let queue = TranscriptionQueue(
        logger: Logger(subsystem: "com.spokium.mac", category: "TranscriptionQueue")
    )
    var sessionStartedAt: ContinuousClock.Instant?
    var currentRecordingURL: URL?
    var pendingAudioSegments: [URL] = []  // accumulated split segments, transcribed as one unit on stop
    var pendingStartCancel = false
    var isResumingAfterSplit = false

    // Per-session accumulated transcripts. Appended by the queue's onComplete
    // callback, drained by finishSession.
    var sessionTexts: [String] = []

    // Audio-duration accounting for the menu bar status row.
    var currentSegmentStartedAt: ContinuousClock.Instant?
    var pendingSegmentsAudioSeconds: Double = 0  // split segments not yet enqueued

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
        AppDefaults.pushToRecord
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
        queue.abort()

        if recorder.isRunning {
            _ = recorder.stop()
            clearCurrentSegment()
        }

        monitors.stopAll()
        inputLevel = 0

        for url in pendingAudioSegments { try? FileManager.default.removeItem(at: url) }
        pendingAudioSegments = []

        queue.cancelAll()
        await queue.unload()
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
        return await queue.tokenCount(for: text, modelURL: modelURL)
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
            monitors.stopAll()
            inputLevel = 0
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
        queue.cancelAll()
        sessionTexts = []
        pendingSegmentsAudioSeconds = 0
        currentSegmentStartedAt = nil
        for url in pendingAudioSegments { try? FileManager.default.removeItem(at: url) }
        pendingAudioSegments = []
        state = .idle
        monitors.stopEscape()
    }

    // Transitions out of recording; goes to .finishing if transcriptions are pending, else .idle
    func returnFromRecording() {
        if queue.queuedCount > 0 {
            state = .finishing
        } else {
            state = .idle
            monitors.stopEscape()
        }
    }

    // Per-segment monitors: level meter, auto-stop deadline. Called at the
    // start of every fresh segment (initial, post-split resume).
    func startSegmentMonitors() {
        monitors.startLevel(recorder: recorder) { [weak self] level in
            self?.inputLevel = level
        }
        monitors.startAutoStop(after: AppDefaults.maxRecordingMinutes) { [weak self] in
            guard let self, case .recording = self.state else { return }
            self.logger.info("Auto-stopping recording (time limit reached)")
            self.stop()
        }
    }

    func stopSegmentMonitors() {
        monitors.stopLevel()
        inputLevel = 0
        monitors.cancelAutoStop()
    }

    // Session-scoped escape monitor — started once at session start, lives through
    // splits, stops only when the session fully unwinds.
    func startEscape() {
        monitors.startEscape { [weak self] in self?.cancel() }
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
