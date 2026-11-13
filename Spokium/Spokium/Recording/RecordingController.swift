import AppKit
import AVFoundation
import Foundation
import KeyboardShortcuts
import OSLog

@Observable
@MainActor
final class RecordingController {
    var state: RecordingState = .idle {
        didSet {
            // Quiet from the moment the mic starts until stop; transcription needs no quiet.
            let wasCapturing = oldValue == .starting || oldValue == .recording
            let isCapturing = state == .starting || state == .recording
            if isCapturing, !wasCapturing {
                roomQuieter.begin()
            }
            // Once the mic is live (the start chime plays then), not at .starting.
            if state == .recording, oldValue == .starting {
                startMacVolumeDuck()
            }
            if wasCapturing, !isCapturing {
                roomQuieter.end()
                duckTask?.cancel()
                duckTask = nil
                MacVolumeDucker.restore()
            }
        }
    }
    let roomQuieter = RoomQuieter()
    private var duckTask: Task<Void, Never>?

    // With sounds on, the start chime plays as recording goes live; ducking right
    // away would make it inaudible, so let it finish first.
    private func startMacVolumeDuck() {
        guard AppDefaults.macVolumeWhileRecording != .unchanged else { return }
        duckTask?.cancel()
        let delay: Duration = AppDefaults.playSounds ? .milliseconds(500) : .zero
        duckTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.state == .starting || self.state == .recording else { return }
            MacVolumeDucker.duck()
        }
    }

    // Moving rooms mid-recording: un-mute the old device, mute the new one.
    func quietEndpointChanged() {
        guard state == .starting || state == .recording else { return }
        roomQuieter.begin()
    }
    var lastError: RecordingError?
    var persistentError: RecordingError?
    var lastCompletion: CompletionFeedback?
    var inputLevel: Float = 0
    var noAudioWarning = false

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
        let coreML = FileManager.default.fileExists(atPath: WhisperModel.coreMLURL(forModelAt: url).path)
        guard let stats = ModelPerformanceStore.read(modelStem: ModelPerformanceStore.key(modelStem: stem, coreML: coreML)),
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
    let history = TranscriptHistory()
    var sessionStartedAt: ContinuousClock.Instant?
    var currentRecordingURL: URL?
    var pendingAudioSegments: [URL] = []  // accumulated split segments, transcribed as one unit on stop
    var pendingStartCancel = false
    // A stop that arrived while the mic wasn't running yet (push-to-record released
    // during .starting) or was being restarted after a device change. Honoured as soon
    // as recording is live again.
    var pendingStop = false
    // Set when the session was stopped with the "stop and send" shortcut: press Return
    // after the paste.
    var sendAfterPaste = false
    var isResumingAfterSplit = false
    var stopTailTask: Task<Void, Never>?
    var stopRequestedAt: ContinuousClock.Instant?
    private var lastToggleAt: ContinuousClock.Instant?

    // Per-session accumulated transcripts. Appended by the queue's onComplete
    // callback, drained by finishSession.
    var sessionTexts: [String] = []

    // Audio-duration accounting for the menu bar status row.
    var currentSegmentStartedAt: ContinuousClock.Instant?
    var pendingSegmentsAudioSeconds: Double = 0  // split segments not yet enqueued

    // Live-transcription session state, driven by RecordingController+Live.
    var isLiveSession = false
    var liveSink: LiveSampleSink?
    var liveChunker = LiveChunker()
    // Loaded on the first live session and kept: the model is tiny and init isn't free.
    var sileroClassifier: SileroSpeechClassifier?
    var liveAssembler: LiveTranscriptAssembler?
    var livePumpTask: Task<Void, Never>?
    var liveSessionFiles: [URL] = []
    var liveDebugSegments: [DebugSegment] = []
    var liveAudioOffset: Double = 0
    var liveLanguageCharacters: [String: Int] = [:]
    var liveLastLanguage: String?

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.handleKeyDown()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.handleKeyUp()
        }
        KeyboardShortcuts.onKeyDown(for: .toggleRecordingAndSend) { [weak self] in
            self?.handleKeyDown(send: true)
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecordingAndSend) { [weak self] in
            self?.handleKeyUp(send: true)
        }
        recorder.onConfigurationChange = { [weak self] in
            self?.handleAudioConfigurationChange()
        }
        AudioInputDeviceCache.shared.startListening()
        NotificationCenter.default.addObserver(
            forName: .audioInputDevicesChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let removed = note.object as? [AudioInputDevice] ?? []
            MainActor.assumeIsolated {
                self?.inputDevicesChanged(removed: removed)
            }
        }
        // A newly installed Core ML encoder is compiled for the Neural Engine on first
        // load, which can take minutes. Do that now rather than on the next dictation.
        NotificationCenter.default.addObserver(
            forName: .coreMLEncoderChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let modelURL = note.object as? URL else { return }
            MainActor.assumeIsolated {
                guard let self, ModelManager().selectedModelURL == modelURL else { return }
                self.queue.warmUp(modelURL: modelURL)
            }
        }
    }

    private var isPushToRecord: Bool {
        AppDefaults.pushToRecord
    }

    // `send`: the "stop and send" shortcut. It starts recordings like the normal one;
    // only the key that *stops* decides whether Return follows the paste.
    private func handleKeyDown(send: Bool = false) {
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
            toggle(send: send)
        }
    }

    private func handleKeyUp(send: Bool = false) {
        guard isPushToRecord else { return }
        switch state {
        case .recording:
            sendAfterPaste = send
            stop()
        case .starting:
            sendAfterPaste = send
            // The mic takes 100–300 ms to start (1–2 s for Bluetooth); a release in that
            // window used to be dropped and the recording kept running.
            pendingStop = true
        default:
            break
        }
    }

    func cleanup() async {
        roomQuieter.end()
        MacVolumeDucker.restore()
        // Halt whisper between graph computations. unload() below serialises after
        // the in-flight transcribe() exits, so it sees the freed-context state.
        queue.abort()
        stopTailTask?.cancel()
        stopTailTask = nil

        if recorder.isRunning {
            _ = await recorder.stop()
            clearCurrentSegment()
        }

        monitors.stopAll()
        inputLevel = 0

        for url in pendingAudioSegments { try? FileManager.default.removeItem(at: url) }
        pendingAudioSegments = []

        queue.cancelAll()
        endLiveSession(persistDebug: false)
        // Don't leave the last transcript on the clipboard if we quit before the restore.
        ClipboardRestorer.shared.restoreNow()
        history.clear()
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

    func toggle(send: Bool = false) {
        // Rapid start/stop bursts churn AVAudioEngine/aggregate-device setup in coreaudiod
        // and once wedged it (see AudioRecorder). Nobody toggles deliberately this fast.
        let now = ContinuousClock.now
        if let last = lastToggleAt, now - last < .milliseconds(250) { return }
        lastToggleAt = now

        switch state {
        case .idle:
            state = .starting
            Task { await start() }
        case .starting:
            break
        case .recording:
            sendAfterPaste = send
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
            pendingStop = false
            sendAfterPaste = false
            logger.info("Recording start cancellation requested")
        case .recording:
            monitors.stopAll()
            inputLevel = 0
            discardRecorderAsync()
            cancelAllPending()
            logger.info("Recording cancelled")
        case .finishing:
            if let tail = stopTailTask {
                tail.cancel()
                stopTailTask = nil
                discardRecorderAsync()
            }
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
        endLiveSession(persistDebug: false)
        state = .idle
        monitors.stopEscape()
    }

    // Transitions out of recording; goes to .finishing if transcriptions are pending, else .idle
    // `keepPendingText` is false only for an explicit cancel. A continued session whose
    // new segment fails to start must still paste the text from its first part.
    func returnFromRecording(keepPendingText: Bool = true) {
        if queue.queuedCount > 0 {
            state = .finishing
        } else if keepPendingText, hasPendingText {
            state = .finishing
            finishSession()
        } else {
            state = .idle
            monitors.stopEscape()
        }
    }

    private var hasPendingText: Bool {
        if isLiveSession { return !(liveAssembler?.text.isEmpty ?? true) }
        return !sessionTexts.isEmpty
    }

    // Per-segment monitors: level meter, auto-stop deadline. Called at the
    // start of every fresh segment (initial, post-split resume).
    func startSegmentMonitors() {
        noAudioWarning = false
        monitors.startLevel(
            recorder: recorder,
            onUpdate: { [weak self] level in
                self?.inputLevel = level
            },
            onSilenceDetected: { [weak self] heardAudioBefore in
                guard let self else { return }
                self.logger.warning("No audio detected for 5s (heard audio before: \(heardAudioBefore)) — surfacing dead-mic warning")
                self.noAudioWarning = true
                // Only a mic that never produced audio gets the chime. After a pause
                // mid-recording the chime would be picked up and transcribed.
                if !heardAudioBefore {
                    RecordingSounds.playWarning()
                }
            },
            onAudioResumed: { [weak self] in
                guard let self else { return }
                self.logger.info("Audio resumed after dead-mic warning")
                self.noAudioWarning = false
            }
        )
        monitors.startAutoStop(after: AppDefaults.maxRecordingMinutes) { [weak self] in
            guard let self, case .recording = self.state else { return }
            self.logger.info("Auto-stopping recording (time limit reached)")
            self.stop()
        }
    }

    func stopSegmentMonitors() {
        monitors.stopLevel()
        inputLevel = 0
        noAudioWarning = false
        monitors.cancelAutoStop()
    }

    // Session-scoped escape monitor — started once at session start, lives through
    // splits, stops only when the session fully unwinds.
    func startEscape() {
        monitors.startEscape { [weak self] in self?.cancel() }
    }

    // Stops the engine off the main thread and deletes the segment it was writing.
    func discardRecorderAsync() {
        let url = currentRecordingURL
        currentRecordingURL = nil
        Task {
            _ = await recorder.stop()
            if let url { try? FileManager.default.removeItem(at: url) }
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
        // The suffix keeps two recordings started within the same second apart: a
        // cancelled one's async delete could otherwise remove the new file.
        let suffix = UUID().uuidString.prefix(8)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(timestamp)-\(suffix).caf")
    }
}
