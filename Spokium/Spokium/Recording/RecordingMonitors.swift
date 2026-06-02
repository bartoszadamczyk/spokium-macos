import AppKit
import Foundation
import OSLog

// Owns the timers/monitors that bracket a recording session:
//   - level polling (50ms RMS samples → smoothed Float)
//   - auto-stop deadline
//   - global Esc keyDown monitor
//
// All callbacks run on MainActor. RecordingController holds one instance and
// drives starts/stops at the appropriate state-machine transitions.
//
// Mid-recording segment splitting (used for device-switch handoff) is driven
// from RecordingController.splitCurrentSegment directly — no timer involved.
final class RecordingMonitors {
    private var levelTimer: Timer?
    private var autoStopTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var smoothedLevel: Float = 0
    private var silentTicks: Int = 0
    private var noAudioFired = false
    private var noAudioActive = false

    // Dead-mic detection runs throughout the segment, not just at startup:
    //   - Each tick, if raw input is below a near-zero threshold, advance a
    //     silent-tick counter; otherwise reset it.
    //   - After 5s of continuous silence the warning fires *once* per segment
    //     (onSilenceDetected) — orange HUD + Sosumi chime.
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
        onSilenceDetected: (@MainActor () -> Void)? = nil,
        onAudioResumed: (@MainActor () -> Void)? = nil
    ) {
        levelTimer?.invalidate()
        smoothedLevel = 0
        silentTicks = 0
        noAudioFired = false
        noAudioActive = false
        let smoothing: Float = 0.3
        let silenceThreshold: Float = 0.001
        let ticksBeforeWarning = 100  // 100 * 0.05s = 5.0s
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let raw = recorder.currentLevel
                self.smoothedLevel = self.smoothedLevel * (1 - smoothing) + raw * smoothing
                onUpdate(self.smoothedLevel)

                if raw >= silenceThreshold {
                    self.silentTicks = 0
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
                        onSilenceDetected()
                    }
                }
            }
        }
    }

    func stopLevel() {
        levelTimer?.invalidate()
        levelTimer = nil
        smoothedLevel = 0
        silentTicks = 0
        noAudioFired = false
        noAudioActive = false
    }

    func startAutoStop(after minutes: Double, onFire: @escaping @MainActor () -> Void) {
        autoStopTask?.cancel()
        guard minutes > 0 else { return }
        let nanoseconds = UInt64(minutes * 60 * 1_000_000_000)
        autoStopTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { onFire() }
        }
    }

    func cancelAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    func startEscape(onPress: @escaping @MainActor () -> Void) {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in onPress() }
        }
    }

    func stopEscape() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    func stopAll() {
        stopLevel()
        cancelAutoStop()
        stopEscape()
    }
}
