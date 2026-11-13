import AVFoundation
import Foundation
import OSLog

extension RecordingController {
    func start() async {
        lastError = nil
        persistentError = nil
        pendingStartCancel = false
        pendingStop = false
        sendAfterPaste = false
        sessionTexts = []
        pendingSegmentsAudioSeconds = 0
        currentSegmentStartedAt = nil
        sessionStartedAt = nil
        pendingAudioSegments = []

        let manager = ModelManager()
        guard let modelURL = manager.selectedModelURL else {
            state = .idle
            reportError(.noModel)
            return
        }
        // Load while the user speaks rather than when the first chunk arrives.
        queue.warmUp(modelURL: modelURL)

        beginLiveSessionIfEnabled()
        await startSegment(playSound: true)
    }

    // Starts a new recording segment within the current session (transcription still running)
    func continueSession() {
        // Still capturing the stop tail of the previous recording; the recorder is busy.
        guard stopTailTask == nil else { return }
        let manager = ModelManager()
        guard manager.selectedModelURL != nil else {
            reportError(.noModel)
            return
        }
        pendingStartCancel = false
        pendingStop = false
        sendAfterPaste = false
        pendingAudioSegments = []
        state = .starting
        Task { await startSegment(playSound: false) }
    }

    func startSegment(playSound: Bool) async {
        let url = makeTempURL()
        currentRecordingURL = url
        do {
            try await recorder.start(to: url)
            if pendingStartCancel {
                _ = await recorder.stop()
                clearCurrentSegment()
                returnFromRecording(keepPendingText: false)
                logger.info("Recording start cancelled")
                return
            }
            if sessionStartedAt == nil { sessionStartedAt = .now }
            state = .recording
            currentSegmentStartedAt = .now
            startSegmentMonitors()
            startEscape()
            startLivePump()
            if playSound { RecordingSounds.playStart() }
            logger.info("Recording segment started")
            honourPendingStop()
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

    // Audio still in the tap pipeline when the engine stops is lost, which clipped the
    // last word when people stop the moment they finish speaking. Keep capturing for a
    // short tail after the stop request; the UI moves to .finishing immediately.
    static let stopTail: Duration = .milliseconds(300)

    func stop() {
        guard stopTailTask == nil else { return }
        guard recorder.isRunning else {
            // Mic still starting, or being restarted after a device change: remember it.
            if state == .starting || isResumingAfterSplit {
                pendingStop = true
                logger.info("Stop requested while the mic isn't running yet — deferred")
            }
            return
        }

        state = .finishing
        stopSegmentMonitors()
        stopRequestedAt = .now

        stopTailTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stopTail)
            guard let self, !Task.isCancelled else { return }
            await self.finishStop()
            self.stopTailTask = nil
        }
    }

    // Called once recording is live again (segment start, resume after a split).
    func honourPendingStop() {
        guard pendingStop, case .recording = state else { return }
        pendingStop = false
        logger.info("Applying deferred stop")
        stop()
    }

    private func finishStop() async {
        let url = await recorder.stop()
        // Cancelled while the engine was stopping: cancel() already reset the
        // session, so drop this segment instead of transcribing it.
        if Task.isCancelled {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }
        // The tail is over. From here, queue-idle callbacks may finish the session again;
        // during the tail they were ignored (a chunk finishing then must not end it early).
        stopTailTask = nil
        currentRecordingURL = nil
        currentSegmentStartedAt = nil

        var segments = pendingAudioSegments
        pendingAudioSegments = []
        let priorSegmentsAudio = pendingSegmentsAudioSeconds
        pendingSegmentsAudioSeconds = 0

        if isLiveSession {
            if let url { segments.append(url) }
            finishLiveRecording(segmentURLs: segments)
            return
        }

        if let url {
            segments.append(url)
        } else if segments.isEmpty {
            reportError(.recordingFailed("Audio recording failed to save."))
            // An idle signal during the tail was ignored, so finish here if nothing is
            // queued: paste what a continued session already has, or go idle.
            if queue.queuedCount == 0 {
                if sessionTexts.isEmpty {
                    state = .idle
                    monitors.stopEscape()
                } else {
                    finishSession()
                }
            }
            return
        } else {
            logger.warning("Final segment failed to save — transcribing prior segments only")
        }

        let finalSegmentAudio = url.map { audioDuration(at: $0) } ?? 0
        enqueueTranscription(urls: segments, audioSeconds: priorSegmentsAudio + finalSegmentAudio)
    }

    private func enqueueTranscription(urls: [URL], audioSeconds: Double) {
        let manager = ModelManager()
        guard let modelURL = manager.selectedModelURL else {
            for url in urls { try? FileManager.default.removeItem(at: url) }
            reportError(.noModel)
            return
        }
        let prompt = dictionaryPrompt()
        let settings = transcriptionSettings()
        queue.enqueue(
            source: .files(urls),
            audioSeconds: audioSeconds,
            modelURL: modelURL,
            initialPrompt: { prompt },
            settings: { settings },
            sessionStartedAt: sessionStartedAt,
            onComplete: { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .success(let result):
                    if !result.text.isEmpty { self.sessionTexts.append(result.text) }
                case .failure(let error):
                    self.reportError(error)
                case .cancelled:
                    break
                }
            },
            onIdle: { [weak self] in
                // Not during the stop tail: the recorder is still capturing and
                // finishStop() will queue (or finish) the rest itself.
                guard let self, case .finishing = self.state, self.stopTailTask == nil else { return }
                self.finishSession()
            }
        )
    }

    func finishSession() {
        monitors.stopEscape()
        let wasLive = isLiveSession

        let combined: String
        if isLiveSession {
            combined = liveAssembler?.text ?? ""
            endLiveSession(persistDebug: true)
        } else {
            combined = sessionTexts.joined(separator: " ")
        }
        sessionTexts = []
        sessionStartedAt = nil

        let finalText = SnippetStore.apply(to: combined)
        logger.info("Session finished: chars=\(finalText.count)")
        let stoppedAt = stopRequestedAt
        stopRequestedAt = nil
        let send = sendAfterPaste
        sendAfterPaste = false
        guard !finalText.isEmpty else {
            lastCompletion = .empty
            RecordingSounds.playEmpty()
            state = .idle
            return
        }

        if AppDefaults.keepRecentTranscripts {
            history.add(finalText)
        }

        Task { [weak self] in
            guard let self else { return }
            let result = await Paster.paste(finalText)
            let latency = stoppedAt.map { Self.seconds(of: ContinuousClock.now - $0) }
            self.logger.notice("Paste result: \(String(describing: result), privacy: .public), stop→paste=\(latency.map { String(format: "%.2fs", $0) } ?? "n/a", privacy: .public), live=\(wasLive)")
            switch result {
            case .pasted:
                self.lastCompletion = .pasted
                RecordingSounds.playPaste()
                // Only after a real paste: with copy-only or a failed paste there is
                // nothing in the field to send.
                if send {
                    await Paster.pressReturn()
                    self.logger.notice("Pressed Return after paste (stop and send)")
                }
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

    func transcriptionSettings() -> TranscriptionSettings {
        let allowed = AppDefaults.selectedLanguage == "auto" ? AppDefaults.autoDetectLanguages : []
        return TranscriptionSettings(
            language: AppDefaults.selectedLanguage,
            allowedLanguages: allowed,
            fallbackLanguage: LanguageChooser.dominant(charactersByLanguage: LanguageUsageStore.all(), allowed: allowed),
            paragraphSplitting: AppDefaults.paragraphSplitting,
            minSilenceDuration: AppDefaults.silenceThreshold
        )
    }

    func dictionaryPrompt() -> String? {
        DictionaryPromptBuilder.prompt(from: AppDefaults.dictionaryEntries)
    }
}
