import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = RecordingController()

    // Shared with extensions in this folder. Kept internal (not private) so
    // AppDelegate+Menu / +Submenus / +StatusItem / +Errors can reach them.
    var statusItem: NSStatusItem!
    var toggleMenuItem: NSMenuItem!
    var cancelMenuItem: NSMenuItem!
    var queueStatusItem: NSMenuItem!
    var inputDeviceMenu: NSMenu!
    var modelMenu: NSMenu!
    var errorRowItem: NSMenuItem!
    var errorActionItem: NSMenuItem!
    var disableAutoPasteItem: NSMenuItem!
    var dismissErrorItem: NSMenuItem!
    var errorSeparator: NSMenuItem!
    let recordingOverlay = RecordingOverlay()
    var pulseTimer: Timer?
    var pulseOn = true
    var queueStatusTimer: Timer?

    let settingsScene = NSHostingSceneRepresentation {
        Settings {
            SettingsSceneRoot()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        cleanStaleTempFiles()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        statusItem = item

        applyState(controller.state)
        observeState()
        observeErrors()
        observePersistentError()
        observeStateForInputDeviceMenu()
    }

    private func observeStateForInputDeviceMenu() {
        withObservationTracking { [weak self] in
            _ = self?.controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshInputDeviceMenu()
                self.observeStateForInputDeviceMenu()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await controller.cleanup()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func observeState() {
        withObservationTracking { [weak self] in
            _ = self?.controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyState(self.controller.state)
                self.observeState()
            }
        }
    }

    func applyState(_ state: RecordingState) {
        let recording = state == .recording
        toggleMenuItem.title = recording ? "Stop Recording" : "Start Recording"
        toggleMenuItem.image = NSImage(
            systemSymbolName: recording ? "stop.fill" : "mic.fill",
            accessibilityDescription: nil
        )
        cancelMenuItem.isHidden = state == .idle
        cancelMenuItem.title = state == .finishing ? "Cancel Transcription" : "Cancel Recording"

        switch state {
        case .recording:
            recordingOverlay.show(mode: .recording, controller: controller)
            startPulse()
        case .starting:
            stopPulse()
        case .finishing:
            recordingOverlay.show(mode: .transcribing, controller: controller)
            stopPulse()
        case .idle:
            if let feedback = controller.lastCompletion {
                recordingOverlay.showFeedback(feedback, controller: controller)
                controller.clearCompletion()
            } else {
                recordingOverlay.hide()
            }
            stopPulse()
        }

        renderMenuBarIcon(recording: recording)
        refreshQueueStatus()
    }

    func cleanStaleTempFiles() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("whisper-") && file.pathExtension == "caf" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    @objc func openSettings() {
        settingsScene.environment.openSettings()
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
