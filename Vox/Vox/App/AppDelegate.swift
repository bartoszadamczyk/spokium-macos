import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = RecordingController()

    private var statusItem: NSStatusItem!
    private var toggleMenuItem: NSMenuItem!
    private var cancelMenuItem: NSMenuItem!
    private var inputDeviceMenu: NSMenu!
    private var modelMenu: NSMenu!
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

        cancelMenuItem = NSMenuItem(
            title: "Cancel Recording",
            action: #selector(cancelRecording),
            keyEquivalent: ""
        )
        cancelMenuItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        cancelMenuItem.target = self
        cancelMenuItem.isHidden = true
        menu.addItem(cancelMenuItem)

        menu.addItem(.separator())

        inputDeviceMenu = NSMenu()
        let inputDeviceItem = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        inputDeviceItem.submenu = inputDeviceMenu
        menu.addItem(inputDeviceItem)

        modelMenu = NSMenu()
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

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
        cancelMenuItem.isHidden = state == .idle
        cancelMenuItem.title = state == .finishing ? "Cancel Transcription" : "Cancel Recording"

        switch state {
        case .recording:
            recordingOverlay.show(mode: .recording, controller: controller)
            startPulse()
        case .finishing:
            recordingOverlay.show(mode: .transcribing, controller: controller)
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
                    self.statusItem.button?.animator().alphaValue = self.pulseOn ? 1.0 : 0.45
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
        refreshInputDeviceMenu()
        refreshModelMenu()
    }

    @objc private func toggleRecording() {
        controller.toggle()
    }

    @objc private func cancelRecording() {
        controller.cancel()
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
        case .microphoneDenied:
            alert.messageText = "Microphone Access Required"
            alert.informativeText = "Vox needs microphone access to record audio. Grant permission in System Settings → Privacy & Security → Microphone."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .recordingFailed(let detail):
            alert.messageText = "Recording Failed"
            alert.informativeText = detail
            alert.addButton(withTitle: "OK")
            alert.runModal()
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

    private func refreshInputDeviceMenu() {
        inputDeviceMenu.removeAllItems()
        let selectedUID = UserDefaults.standard.string(forKey: "selectedInputDevice") ?? ""

        let defaultName = AudioInputDevice.defaultInputName() ?? "Unknown"
        let defaultItem = NSMenuItem(title: "System Default (\(defaultName))", action: #selector(selectInputDevice(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = "" as String
        defaultItem.state = selectedUID.isEmpty ? .on : .off
        inputDeviceMenu.addItem(defaultItem)

        let devices = AudioInputDevice.available()
        if !devices.isEmpty {
            inputDeviceMenu.addItem(.separator())
        }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectInputDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == selectedUID ? .on : .off
            inputDeviceMenu.addItem(item)
        }
    }
    
    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        UserDefaults.standard.set(uid, forKey: "selectedInputDevice")
    }

    private func refreshModelMenu() {
        modelMenu.removeAllItems()
        let manager = ModelManager()
        let downloaded = WhisperModel.all.filter { manager.downloadedNames.contains($0.name) }

        if downloaded.isEmpty {
            let empty = NSMenuItem(title: "No models downloaded", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            modelMenu.addItem(empty)
            modelMenu.addItem(.separator())
        } else {
            for model in downloaded {
                let item = NSMenuItem(
                    title: "\(model.displayName) (\(model.sizeLabel))",
                    action: #selector(selectModel(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = model.name
                item.state = manager.selectedModelName == model.name ? .on : .off
                modelMenu.addItem(item)
            }
            modelMenu.addItem(.separator())
        }

        let manage = NSMenuItem(title: "Manage Models…", action: #selector(openSettings), keyEquivalent: "")
        manage.target = self
        modelMenu.addItem(manage)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let manager = ModelManager()
        manager.selectedModelName = name
    }

    @objc private func openSettings() {
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
