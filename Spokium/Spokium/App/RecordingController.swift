import AppKit
import AVFoundation
import Foundation
import KeyboardShortcuts
import OSLog

enum RecordingState: Equatable {
    case idle
    case starting
    case recording
    case finishing
}

enum RecordingError: Equatable {
    case noModel
    case microphoneDenied
    case recordingFailed(String)
    case transcriptionFailed(String)
    case downloadFailed(String)
    case noAccessibility

    var menuMessage: String {
        switch self {
        case .noModel: "No Whisper model selected"
        case .microphoneDenied: "Microphone access denied"
        case .recordingFailed: "Recording failed"
        case .transcriptionFailed: "Transcription failed"
        case .downloadFailed: "Model download failed"
        case .noAccessibility: "Paste blocked — Accessibility permission needed"
        }
    }
}

enum CompletionFeedback: Equatable {
    case pasted
    case copied
    case empty
    case failed(String)
}

@Observable
@MainActor
final class RecordingController {
    private(set) var state: RecordingState = .idle
    private(set) var lastError: RecordingError?
    private(set) var persistentError: RecordingError?
    private(set) var lastCompletion: CompletionFeedback?
    private(set) var inputLevel: Float = 0

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

    private static func seconds(of duration: Duration) -> Double {
        let (sec, atto) = duration.components
        return Double(sec) + Double(atto) * 1e-18
    }

    private let recorder = AudioRecorder()
    private let logger = Logger(subsystem: "com.bartoszadamczyk.Spokium", category: "Recording")
    private var transcriber: Transcriber?
    private var sessionStartedAt: ContinuousClock.Instant?
    private var activeTasks: [Task<Void, Never>] = []
    private var lastTranscriptionTask: Task<Void, Never>?  // tail of the serial chain
    private var levelTimer: Timer?
    private var escapeMonitor: Any?
    private var autoStopTask: Task<Void, Never>?
    private var splitTimer: Timer?
    private var currentRecordingURL: URL?
    private var pendingAudioSegments: [URL] = []  // accumulated split segments, transcribed as one unit on stop
    private var pendingStartCancel = false
    private var isResumingAfterSplit = false

    // Session: one or more consecutive recordings whose results are concatenated
    private var sessionTexts: [String] = []
    private var pendingTranscriptionCount = 0

    // Audio-duration accounting for the menu bar status row.
    private var currentSegmentStartedAt: ContinuousClock.Instant?
    private var pendingSegmentsAudioSeconds: Double = 0  // split segments not yet enqueued
    private var pendingTranscriptionAudioSeconds: Double = 0  // queued + in-progress
    private var currentTranscriptionStartedAt: ContinuousClock.Instant?

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

    // Shared segment-split path: saves current segment, enqueues transcription, restarts recorder.
    // Used for device switches and auto-split timer.
    private func splitCurrentSegment() {
        // Drop re-entrant calls: Continuity Mic fires multiple config-change notifications
        // while the device is still initialising — ignore them until the resume finishes.
        guard case .recording = state else {
            logger.info("splitCurrentSegment: skipped — state=\(String(describing: self.state), privacy: .public)")
            return
        }
        guard !isResumingAfterSplit else {
            logger.info("splitCurrentSegment: skipped — already resuming after split")
            return
        }

        stopLevelMonitoring()
        stopSplitTimer()
        autoStopTask?.cancel()
        autoStopTask = nil

        currentSegmentStartedAt = nil
        if let url = recorder.stop() {
            currentRecordingURL = nil
            let duration = audioDuration(at: url)
            if duration >= 0.25 {
                pendingAudioSegments.append(url)
                pendingSegmentsAudioSeconds += duration
            } else {
                // Continuity Mic can "start" before producing audio, leaving a header-only
                // file behind when the next config-change notification splits us again.
                logger.info("Discarding empty split segment \(url.lastPathComponent, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            clearCurrentSegment()
        }

        Task { await self.resumeRecordingAfterSplit() }
    }

    private func audioDuration(at url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // Called when system audio config changes (device plugged/unplugged) OR when user
    // explicitly switches device mid-recording via switchInputDevice().
    private func handleAudioConfigurationChange() {
        logger.info("Audio config change — state=\(String(describing: self.state), privacy: .public) isResumingAfterSplit=\(self.isResumingAfterSplit)")
        splitCurrentSegment()
    }

    private func resumeRecordingAfterSplit() async {
        guard case .recording = state else {
            logger.info("resumeRecordingAfterSplit: exiting early — state=\(String(describing: self.state), privacy: .public)")
            return
        }
        isResumingAfterSplit = true
        defer {
            logger.info("resumeRecordingAfterSplit: clearing isResumingAfterSplit")
            isResumingAfterSplit = false
        }
        logger.info("resumeRecordingAfterSplit: starting retry loop")

        // Continuity Mic fires AVAudioEngineConfigurationChange before the device is fully
        // ready, then fires again once it is. The isResumingAfterSplit guard suppresses those
        // extra notifications while we work through an exponential back-off retry.
        let retryDelaysMs = [0, 500, 1500, 3500, 6000]
        for (i, delayMs) in retryDelaysMs.enumerated() {
            if delayMs > 0 {
                logger.info("resumeRecordingAfterSplit: waiting \(delayMs)ms before attempt \(i + 1)")
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard case .recording = state else {
                    logger.info("resumeRecordingAfterSplit: aborting after sleep — state=\(String(describing: self.state), privacy: .public)")
                    return
                }
            }

            let url = makeTempURL()
            currentRecordingURL = url
            logger.info("resumeRecordingAfterSplit: attempt \(i + 1)/\(retryDelaysMs.count)")
            do {
                try await recorder.start(to: url)
                state = .recording
                currentSegmentStartedAt = .now
                startLevelMonitoring()
                startAutoStopTask()
                startSplitTimer()
                logger.info("resumeRecordingAfterSplit: succeeded on attempt \(i + 1) (\(delayMs)ms delay)")
                return
            } catch {
                clearCurrentSegment()
                logger.warning("resumeRecordingAfterSplit: attempt \(i + 1) failed: \(error.localizedDescription, privacy: .public) (code=\((error as NSError).code))")
            }
        }

        // Selected device is likely disconnected. Fall back to system default and try once more.
        let lostDevice = UserDefaults.standard.string(forKey: "selectedInputDevice") ?? ""
        if !lostDevice.isEmpty {
            logger.warning("resumeRecordingAfterSplit: selected device unavailable — falling back to system default")
            UserDefaults.standard.set("", forKey: "selectedInputDevice")

            let url = makeTempURL()
            currentRecordingURL = url
            do {
                try await recorder.start(to: url)
                state = .recording
                currentSegmentStartedAt = .now
                startLevelMonitoring()
                startAutoStopTask()
                startSplitTimer()
                logger.info("resumeRecordingAfterSplit: succeeded on system default after device disconnect")
                return
            } catch {
                clearCurrentSegment()
                logger.error("resumeRecordingAfterSplit: fallback to system default also failed: \(error.localizedDescription, privacy: .public) (code=\((error as NSError).code))")
            }
        }

        logger.error("resumeRecordingAfterSplit: all attempts exhausted — reporting error and exiting")
        reportError(.recordingFailed("Could not resume recording after audio device change."))
        returnFromRecording()
    }

    // Switches input device while recording without losing audio.
    func switchInputDevice(uid: String) {
        let previousUID = UserDefaults.standard.string(forKey: "selectedInputDevice") ?? ""
        UserDefaults.standard.set(uid, forKey: "selectedInputDevice")
        guard case .recording = state else { return }

        // Skip the segment split if the previous and new selections resolve to the
        // same physical device (e.g. "System Default" → the explicit mic that *is*
        // the default). Hardware hasn't changed, so there's nothing to restart.
        if resolvedDeviceUID(for: previousUID) == resolvedDeviceUID(for: uid) {
            logger.info("switchInputDevice: same physical device — skipping split")
            return
        }

        handleAudioConfigurationChange()
    }

    private func resolvedDeviceUID(for selectedUID: String) -> String? {
        selectedUID.isEmpty ? AudioInputDevice.defaultInputUID() : selectedUID
    }

    private func clearCurrentSegment() {
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
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
        stopEscapeMonitor()
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

    private func reportError(_ error: RecordingError) {
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

    // Starts a new recording segment within the current session (transcription still running)
    private func continueSession() {
        let manager = ModelManager()
        guard manager.selectedModelURL != nil else {
            reportError(.noModel)
            return
        }
        pendingStartCancel = false
        pendingAudioSegments = []
        state = .starting
        Task { await startSegment(playSound: false) }
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

    private func cancelAllPending() {
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

    private func start() async {
        lastError = nil
        persistentError = nil
        pendingStartCancel = false
        sessionTexts = []
        pendingTranscriptionCount = 0
        pendingTranscriptionAudioSeconds = 0
        pendingSegmentsAudioSeconds = 0
        currentSegmentStartedAt = nil
        currentTranscriptionStartedAt = nil
        lastTranscriptionTask = nil
        sessionStartedAt = nil
        pendingAudioSegments = []

        let manager = ModelManager()
        guard manager.selectedModelURL != nil else {
            state = .idle
            reportError(.noModel)
            return
        }

        await startSegment(playSound: true)
    }

    private func startSegment(playSound: Bool) async {
        let url = makeTempURL()
        currentRecordingURL = url
        do {
            try await recorder.start(to: url)
            if pendingStartCancel {
                _ = recorder.stop()
                clearCurrentSegment()
                returnFromRecording()
                logger.info("Recording start cancelled")
                return
            }
            if sessionStartedAt == nil { sessionStartedAt = .now }
            state = .recording
            currentSegmentStartedAt = .now
            startLevelMonitoring()
            startEscapeMonitor()
            startAutoStopTask()
            startSplitTimer()
            if playSound { RecordingSounds.playStart() }
            logger.info("Recording segment started")
        } catch AudioRecorderError.microphoneDenied {
            clearCurrentSegment()
            returnFromRecording()
            reportError(.microphoneDenied)
        } catch {
            clearCurrentSegment()
            returnFromRecording()
            logger.error("startSegment failed: \(error.localizedDescription, privacy: .public) (code=\((error as NSError).code)) isResumingAfterSplit=\(self.isResumingAfterSplit)")
            reportError(.recordingFailed(error.localizedDescription))
        }
    }

    // Transitions out of recording; goes to .finishing if transcriptions are pending, else .idle
    private func returnFromRecording() {
        if pendingTranscriptionCount > 0 {
            state = .finishing
        } else {
            state = .idle
            stopEscapeMonitor()
        }
    }

    private func stop() {
        guard recorder.isRunning else { return }

        state = .finishing
        stopLevelMonitoring()
        stopSplitTimer()
        autoStopTask?.cancel()
        autoStopTask = nil

        let url = recorder.stop()
        currentRecordingURL = nil
        currentSegmentStartedAt = nil

        var segments = pendingAudioSegments
        pendingAudioSegments = []
        let priorSegmentsAudio = pendingSegmentsAudioSeconds
        pendingSegmentsAudioSeconds = 0

        if let url {
            segments.append(url)
        } else if segments.isEmpty {
            reportError(.recordingFailed("Audio recording failed to save."))
            if pendingTranscriptionCount == 0 {
                state = .idle
                stopEscapeMonitor()
            }
            return
        } else {
            logger.warning("Final segment failed to save — transcribing prior segments only")
        }

        let finalSegmentAudio = url.map { audioDuration(at: $0) } ?? 0
        enqueueTranscription(urls: segments, audioSeconds: priorSegmentsAudio + finalSegmentAudio)
    }

    private func enqueueTranscription(urls: [URL], audioSeconds: Double) {
        guard !urls.isEmpty else { return }
        pendingTranscriptionCount += 1
        pendingTranscriptionAudioSeconds += audioSeconds
        let previous = lastTranscriptionTask
        let task = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled, let self else {
                for url in urls { try? FileManager.default.removeItem(at: url) }
                return
            }
            await self.transcribeSession(urls: urls, audioSeconds: audioSeconds)
        }
        lastTranscriptionTask = task
        activeTasks.append(task)
    }

    private func transcribeSession(urls: [URL], audioSeconds: Double) async {
        defer {
            for url in urls { try? FileManager.default.removeItem(at: url) }
            pendingTranscriptionCount -= 1
            pendingTranscriptionAudioSeconds = max(0, pendingTranscriptionAudioSeconds - audioSeconds)
            if pendingTranscriptionCount == 0 {
                currentTranscriptionStartedAt = nil
            }
            activeTasks.removeAll { $0.isCancelled }
            if pendingTranscriptionCount == 0, case .finishing = state {
                finishSession()
            }
        }

        guard !Task.isCancelled else { return }

        let manager = ModelManager()
        guard let modelURL = manager.selectedModelURL else {
            reportError(.noModel)
            return
        }

        if transcriber?.modelURL != modelURL { transcriber = nil }
        let transcriber = self.transcriber ?? Transcriber(modelURL: modelURL)
        self.transcriber = transcriber

        currentTranscriptionStartedAt = .now

        // Load and concatenate all segment audio into one sample array at 16 kHz mono.
        // AudioLoader.loadResampled handles format differences between segments (e.g. after a device switch).
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
                initialPrompt: dictionaryPrompt(),
                settings: transcriptionSettings()
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

            if !result.text.isEmpty {
                sessionTexts.append(result.text)
            }
        } catch TranscriberError.cancelled {
            logger.info("Transcription aborted")
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            reportError(.transcriptionFailed(error.localizedDescription))
        }
    }

    private func finishSession() {
        stopEscapeMonitor()

        let combined = sessionTexts.joined(separator: " ")
        sessionTexts = []
        sessionStartedAt = nil

        let finalText = SnippetStore.apply(to: combined)
        guard !finalText.isEmpty else {
            lastCompletion = .empty
            RecordingSounds.playEmpty()
            state = .idle
            return
        }

        Task { [weak self] in
            guard let self else { return }
            switch await Paster.paste(finalText) {
            case .pasted:
                self.lastCompletion = .pasted
                RecordingSounds.playPaste()
            case .copied:
                self.lastCompletion = .copied
                RecordingSounds.playPaste()
            case .failedNoAccessibility:
                self.lastCompletion = .failed("Accessibility permission needed")
                self.persistentError = .noAccessibility
                Paster.requestAccessibilityPermission()
            }
            self.state = .idle
        }
    }

    private func transcriptionSettings() -> TranscriptionSettings {
        let defaults = UserDefaults.standard
        return TranscriptionSettings(
            language: defaults.string(forKey: "selectedLanguage") ?? "auto",
            paragraphSplitting: defaults.object(forKey: "paragraphSplitting") as? Bool ?? true,
            minSilenceDuration: defaults.object(forKey: "silenceThreshold") as? Double ?? 1.5
        )
    }

    private func dictionaryPrompt() -> String? {
        let raw = UserDefaults.standard.string(forKey: "dictionaryEntries") ?? ""
        let entries = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return nil }
        return entries.joined(separator: ", ")
    }

    private func startLevelMonitoring() {
        levelTimer?.invalidate()
        let smoothing: Float = 0.3
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let raw = self.recorder.currentLevel
                self.inputLevel = self.inputLevel * (1 - smoothing) + raw * smoothing
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        inputLevel = 0
    }

    private func startAutoStopTask() {
        autoStopTask?.cancel()
        let minutes = UserDefaults.standard.object(forKey: "maxRecordingMinutes") as? Double ?? 10
        guard minutes > 0 else { return }
        let nanoseconds = UInt64(minutes * 60 * 1_000_000_000)
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, case .recording = self.state else { return }
                self.logger.info("Auto-stopping recording (time limit reached)")
                self.stop()
            }
        }
    }

    private func startSplitTimer() {
        splitTimer?.invalidate()
        let minutes = UserDefaults.standard.object(forKey: "autoSplitMinutes") as? Double ?? 5
        guard minutes > 0 else { return }
        splitTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logger.info("Auto-splitting recording segment")
                self?.splitCurrentSegment()
            }
        }
    }

    private func stopSplitTimer() {
        splitTimer?.invalidate()
        splitTimer = nil
    }

    private func startEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func stopEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    private func makeTempURL() -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(timestamp).caf")
    }
}
