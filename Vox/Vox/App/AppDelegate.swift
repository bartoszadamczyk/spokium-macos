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

    private let settingsScene = NSHostingSceneRepresentation {
        Settings {
            SettingsView()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        statusItem = item

        applyState(controller.state)
        observeState()
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

        if recording {
            recordingOverlay.show()
        } else {
            recordingOverlay.hide()
        }

        let renderer = ImageRenderer(content: MenuBarIcon(recording: state == .recording))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        if let image = renderer.nsImage {
            // Idle icon is a template so macOS adapts it to dark/light menu bar; recording icon
            // keeps its red pill, so it must be marked non-template.
            image.isTemplate = state != .recording
            statusItem.button?.image = image
        }
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

    @objc private func openSettings() {
        NSApp.activate()
        settingsScene.environment.openSettings()
    }
}
