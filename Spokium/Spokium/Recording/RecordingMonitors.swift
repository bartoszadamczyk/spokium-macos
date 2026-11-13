import AppKit
import KeyboardShortcuts
import Foundation
import OSLog

// Owns the timers/monitors that bracket a recording session:
//   - level polling (50ms RMS samples → smoothed Float)
//   - auto-stop deadline
//   - cancel-shortcut key monitors (global + local)
//
// All callbacks run on MainActor. RecordingController holds one instance and
// drives starts/stops at the appropriate state-machine transitions.
//
// Mid-recording segment splitting (used for device-switch handoff) is driven
// from RecordingController.splitCurrentSegment directly — no timer involved.
final class RecordingMonitors {
    private var levelTimer: Timer?
    private var escapeMonitors: [Any] = []
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

    // Two monitors: the global one sees keys sent to other apps (needs the Accessibility
    // permission), the local one keys sent to Spokium's own windows such as Settings.
    func startEscape(onPress: @escaping @MainActor () -> Void) {
        guard escapeMonitors.isEmpty else { return }
        // Monitor handlers run on the main thread.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            MainActor.assumeIsolated {
                guard Self.isCancelShortcut(event) else { return }
                onPress()
            }
        }) {
            escapeMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            let matched = MainActor.assumeIsolated {
                guard Self.isCancelShortcut(event) else { return false }
                onPress()
                return true
            }
            return matched ? nil : event
        }) {
            escapeMonitors.append(local)
        }
    }

    func stopEscape() {
        for monitor in escapeMonitors { NSEvent.removeMonitor(monitor) }
        escapeMonitors = []
    }

    nonisolated static func relevantModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
    }

    private static func isCancelShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .cancelRecording) else { return false }
        return Int(event.keyCode) == shortcut.carbonKeyCode
            && relevantModifiers(of: event) == shortcut.modifiers.subtracting([.function])
    }

    func stopAll() {
        stopLevel()
        cancelAutoStop()
        stopEscape()
    }
}
