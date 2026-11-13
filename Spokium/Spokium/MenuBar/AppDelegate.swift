import AppKit
import OSLog
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
    var quietMenu: NSMenu!
    var quietItem: NSMenuItem!
    var recentTranscriptsItem: NSMenuItem!
    var recentTranscriptsMenu: NSMenu!
    var revealDebugFolderItem: NSMenuItem!
    var defaultsObserver: NSObjectProtocol?
    var errorRowItem: NSMenuItem!
    var errorActionItem: NSMenuItem!
    var disableAutoPasteItem: NSMenuItem!
    var dismissErrorItem: NSMenuItem!
    var errorSeparator: NSMenuItem!
    let recordingOverlay = RecordingOverlay()
    var pulseTimer: Timer?
    var pulseOn = true
    var queueStatusTimer: Timer?

    // Must be registered via addSceneRepresentation before launch finishes, otherwise
    // environment.openSettings() has no scene to present and silently does nothing.
    lazy var settingsScene = NSHostingSceneRepresentation {
        Settings {
            SettingsSceneRoot(controller: self.controller)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.addSceneRepresentation(settingsScene)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        cleanStaleTempFiles()
        DebugRecordingStore.cleanIfDisabled()
        // Repairs a duck left behind by a crash or force-quit mid-recording.
        MacVolumeDucker.restore()
        Self.resetShiftOnlyCancelShortcut()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        statusItem = item

        applyState(controller.state)
        observeState()
        observeErrors()
        observePersistentError()
        observeStateForInputDeviceMenu()
        observeQuitWhenIdle()
        observeDebugModeChanges()
    }

    private func observeDebugModeChanges() {
        // UserDefaults.didChangeNotification fires on any change to standard defaults.
        // We don't filter by key — just re-evaluate debug mode every time. Clean-up
        // and menu-visibility refresh are both idempotent.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                DebugRecordingStore.cleanIfDisabled()
                self?.revealDebugFolderItem?.isHidden = !AppDefaults.debugMode
            }
        }
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
        // cleanup() frees whisper's Metal resources before C++ destructors run, but a
        // model load or a first Core ML compile can't be interrupted and can take
        // minutes. Quit, logout and restart must not wait for that.
        let once = TerminateReplyOnce(sender)
        Task {
            await controller.cleanup()
            once.reply()
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            once.reply()
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

        // For an LSUIElement app, openSettings() creates the window but leaves it
        // ordered out, and SwiftUI's Settings window reports canBecomeMain == false,
        // so it has to be found by identifier and brought forward explicitly. On
        // first open the window appears a run-loop turn or two later, hence the retry.
        Task { @MainActor in
            for _ in 0..<10 {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == Self.settingsWindowID }) {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static let settingsWindowID = "com_apple_SwiftUI_Settings_window"
}

// scripts/release.sh posts this before replacing the app in /Applications. Unlike a
// normal Quit it never interrupts: it waits until nothing is being recorded, transcribed
// or pasted, then quits. The name embeds the bundle ID so dev and production differ.
extension AppDelegate {
    // 1.5.2–1.5.3 allowed (and 1.5.2 defaulted to) ⇧⎋, which a Carbon hotkey can't do.
    static func resetShiftOnlyCancelShortcut() {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .cancelRecording),
              shortcut.modifiers.subtracting([.shift, .function]).isEmpty else { return }
        KeyboardShortcuts.reset(.cancelRecording)
    }
}

nonisolated private let updateLogger = Logger(subsystem: "com.spokium.mac", category: "App")

extension AppDelegate {
    static var quitWhenIdleNotification: Notification.Name {
        Notification.Name("\(Bundle.main.bundleIdentifier ?? "com.spokium.mac").quitWhenIdle")
    }

    func observeQuitWhenIdle() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.quitWhenIdleNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitWhenIdle() }
        }
    }

    private func quitWhenIdle() {
        Task { [weak self] in
            var logged = false
            while let self, self.controller.state != .idle {
                if !logged {
                    logged = true
                    updateLogger.notice("Update requested a quit — waiting for the current dictation to finish")
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // A moment for the paste and any clipboard handling to settle.
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.controller.state == .idle else { return self?.quitWhenIdle() ?? () }
            updateLogger.notice("Quitting for an update")
            // Not NSApp.terminate(nil) directly: from inside a main-actor task, the
            // nested run loop of a .terminateLater quit can't run cleanup's tasks, so
            // Quit deadlocks. A run-loop perform starts it outside the task.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }
}

// Whichever of cleanup and the deadline finishes first answers the terminate request.
private final class TerminateReplyOnce {
    private let app: NSApplication
    private var replied = false

    init(_ app: NSApplication) { self.app = app }

    func reply() {
        guard !replied else { return }
        replied = true
        app.reply(toApplicationShouldTerminate: true)
    }
}
