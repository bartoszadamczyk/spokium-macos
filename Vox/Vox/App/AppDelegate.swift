import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = RecordingController()

    private var statusItem: NSStatusItem!
    private var toggleMenuItem: NSMenuItem!
    private let recordingOverlay = RecordingOverlay()
    private var pulseTimer: Timer?
    private var pulseOn = true

    private let settingsScene = NSHostingSceneRepresentation {
        Settings {
            SettingsView()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ModelLocator.migrateFromOldDirectory()
        cleanStaleTempFiles()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        statusItem = item

        applyState(controller.state)
        observeState()
        observeErrors()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        if !Paster.hasAccessibilityPermission() {
            Paster.requestAccessibilityPermission()
        }
    }

    @objc private func windowDidClose(_ notification: Notification) {
        let hasVisibleWindows = NSApp.windows.contains { $0.isVisible && $0 !== statusItem.button?.window }
        if !hasVisibleWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await controller.cleanup()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        toggleMenuItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        toggleMenuItem.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        toggleMenuItem.target = self
        applyShortcutToMenuItem()
        menu.addItem(toggleMenuItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(
            title: "Quit Vox",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        return menu
    }

    private func observeState() {
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

    private func applyState(_ state: RecordingState) {
        let recording = state == .recording
        toggleMenuItem.title = recording ? "Stop Recording" : "Start Recording"
        toggleMenuItem.image = NSImage(
            systemSymbolName: recording ? "stop.fill" : "mic.fill",
            accessibilityDescription: nil
        )

        switch state {
        case .recording:
            recordingOverlay.show(mode: .recording)
            startPulse()
        case .finishing:
            recordingOverlay.show(mode: .transcribing)
            stopPulse()
        case .idle:
            recordingOverlay.hide()
            stopPulse()
        }

        renderMenuBarIcon(recording: recording)
    }

    private func renderMenuBarIcon(recording: Bool) {
        let renderer = ImageRenderer(content: MenuBarIcon(recording: recording))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        if let image = renderer.nsImage {
            image.isTemplate = !recording
            statusItem.button?.image = image
        }
    }

    private func startPulse() {
        pulseOn = true
        statusItem.button?.alphaValue = 1.0
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pulseOn.toggle()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.6
                    self.statusItem.button?.animator().alphaValue = self.pulseOn ? 1.0 : 0.3
                }
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseOn = true
        statusItem.button?.alphaValue = 1.0
    }

    func menuWillOpen(_ menu: NSMenu) {
        applyShortcutToMenuItem()
    }

    @objc private func toggleRecording() {
        controller.toggle()
    }

    private func applyShortcutToMenuItem() {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            toggleMenuItem.setShortcut(shortcut)
        } else {
            toggleMenuItem.keyEquivalent = ""
            toggleMenuItem.keyEquivalentModifierMask = []
        }
    }

    private func observeErrors() {
        withObservationTracking { [weak self] in
            _ = self?.controller.lastError
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let error = self.controller.lastError else {
                    self?.observeErrors()
                    return
                }
                self.showErrorAlert(error)
                self.controller.dismissError()
                self.observeErrors()
            }
        }
    }

    private func showErrorAlert(_ error: RecordingError) {
        let alert = NSAlert()
        alert.alertStyle = .warning

        switch error {
        case .noModel:
            alert.messageText = "No Whisper Model"
            alert.informativeText = "Download a model in Settings → Model before recording."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                openSettings()
            }
        case .transcriptionFailed(let detail):
            alert.messageText = "Transcription Failed"
            alert.informativeText = detail
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .downloadFailed(let detail):
            alert.messageText = "Download Failed"
            alert.informativeText = detail
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .noAccessibility:
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Vox needs Accessibility access to paste transcribed text. Grant permission in System Settings → Privacy & Security → Accessibility."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func cleanStaleTempFiles() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("whisper-") && file.pathExtension == "caf" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    @objc private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsScene.environment.openSettings()

        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
