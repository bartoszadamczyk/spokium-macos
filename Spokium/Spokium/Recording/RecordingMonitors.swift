import AppKit
import KeyboardShortcuts
import Foundation
import OSLog

// Owns the timers/monitors that bracket a recording session:
//   - level polling (50ms RMS samples → smoothed Float)
//   - auto-stop deadline
//   - cancel hotkey (enabled only while a session is active)
//
// All callbacks run on MainActor. RecordingController holds one instance and
// drives starts/stops at the appropriate state-machine transitions.
//
// Mid-recording segment splitting (used for device-switch handoff) is driven
// from RecordingController.splitCurrentSegment directly — no timer involved.
final class RecordingMonitors {
    private var levelTimer: Timer?
    private var autoStopTask: Task<Void, Never>?
    private var smoothedLevel: Float = 0
    private var silentTicks: Int = 0
    private var noAudioFired = false
    private var noAudioActive = false
    private var heardAudio = false

    // Dead-mic detection runs throughout the segment, not just at startup:
    //   - Each tick, if raw input is below a near-zero threshold, advance a
    //     silent-tick counter; otherwise reset it.
    //   - After 5s of continuous silence the warning fires *once* per segment
    //     (onSilenceDetected). The argument says whether the mic produced any
    //     audio earlier in the segment: if it did, this is just the user pausing
    //     (long live sessions are normal), so the caller shows the HUD without
    //     the chime — a chime would be recorded and transcribed.
    //   - If audio later returns, onAudioResumed clears the visible warning
    //     and the HUD reverts to the level meter.
    //   - The warning will *not* re-fire later in the same segment even if
    //     silence returns. Next mic change (which restarts segment monitors)
    //     or next recording re-arms it.
    //
    // Continuous polling (rather than the previous "first 2s only" check)
    // is what covers Continuity Camera mic and AirPods — those inputs can
    // take a few seconds to wake up, so a startup-window check false-negatives
    // when they're alive and false-positives when they're delayed. The
    // rolling-window approach degrades gracefully in both directions.
    func startLevel(
        recorder: AudioRecorder,
        onUpdate: @escaping @MainActor (Float) -> Void,
        onSilenceDetected: (@MainActor (_ heardAudioBefore: Bool) -> Void)? = nil,
        onAudioResumed: (@MainActor () -> Void)? = nil
    ) {
        levelTimer?.invalidate()
        smoothedLevel = 0
        silentTicks = 0
        noAudioFired = false
        noAudioActive = false
        heardAudio = false
        let smoothing: Float = 0.3
        let silenceThreshold: Float = 0.001
        let ticksBeforeWarning = 100  // 100 * 0.05s = 5.0s
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let raw = recorder.currentLevel
                self.smoothedLevel = self.smoothedLevel * (1 - smoothing) + raw * smoothing
                onUpdate(self.smoothedLevel)

                if raw >= silenceThreshold {
                    self.silentTicks = 0
                    self.heardAudio = true
                    if self.noAudioActive {
                        self.noAudioActive = false
                        onAudioResumed?()
                    }
                } else {
                    self.silentTicks += 1
                    if !self.noAudioFired,
                       self.silentTicks >= ticksBeforeWarning,
                       let onSilenceDetected {
                        self.noAudioFired = true
                        self.noAudioActive = true
                        onSilenceDetected(self.heardAudio)
                    }
                }
            }
        }
        // .common: the default mode pauses while the menu is open, freezing the meter
        // and the dead-mic countdown.
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    func stopLevel() {
        levelTimer?.invalidate()
        levelTimer = nil
        smoothedLevel = 0
        silentTicks = 0
        noAudioFired = false
        noAudioActive = false
        heardAudio = false
    }

    func startAutoStop(after delay: Duration, onFire: @escaping @MainActor () -> Void) {
        autoStopTask?.cancel()
        autoStopTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run { onFire() }
        }
    }

    func cancelAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    func startEscape() {
        KeyboardShortcuts.enable(.cancelRecording)
    }

    func stopEscape() {
        KeyboardShortcuts.disable(.cancelRecording)
    }

    func stopAll() {
        stopLevel()
        cancelAutoStop()
        stopEscape()
    }
}
