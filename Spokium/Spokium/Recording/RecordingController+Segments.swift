import AVFoundation
import Foundation
import OSLog

extension RecordingController {
    // Shared segment-split path: saves current segment, enqueues transcription, restarts recorder.
    // Used for device switches and auto-split timer.
    func splitCurrentSegment() {
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

    // Called when system audio config changes (device plugged/unplugged) OR when user
    // explicitly switches device mid-recording via switchInputDevice().
    func handleAudioConfigurationChange() {
        logger.info("Audio config change — state=\(String(describing: self.state), privacy: .public) isResumingAfterSplit=\(self.isResumingAfterSplit)")
        splitCurrentSegment()
    }

    func resumeRecordingAfterSplit() async {
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
}
