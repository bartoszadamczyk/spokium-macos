import AppKit
import KeyboardShortcuts

extension AppDelegate {
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        errorRowItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorRowItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        errorRowItem.isEnabled = false
        errorRowItem.isHidden = true
        menu.addItem(errorRowItem)

        errorActionItem = NSMenuItem(
            title: "Open Accessibility Settings…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        errorActionItem.target = self
        errorActionItem.isHidden = true
        menu.addItem(errorActionItem)

        disableAutoPasteItem = NSMenuItem(
            title: "Turn Off Auto-paste",
            action: #selector(disableAutoPaste),
            keyEquivalent: ""
        )
        disableAutoPasteItem.target = self
        disableAutoPasteItem.isHidden = true
        menu.addItem(disableAutoPasteItem)

        dismissErrorItem = NSMenuItem(
            title: "Dismiss",
            action: #selector(dismissPersistentError),
            keyEquivalent: ""
        )
        dismissErrorItem.target = self
        dismissErrorItem.isHidden = true
        menu.addItem(dismissErrorItem)

        errorSeparator = .separator()
        errorSeparator.isHidden = true
        menu.addItem(errorSeparator)

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

        queueStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        queueStatusItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        queueStatusItem.isEnabled = false
        queueStatusItem.isHidden = true
        menu.addItem(queueStatusItem)

        menu.addItem(.separator())

        inputDeviceMenu = NSMenu()
        inputDeviceMenu.autoenablesItems = false
        let inputDeviceItem = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        inputDeviceItem.submenu = inputDeviceMenu
        menu.addItem(inputDeviceItem)

        modelMenu = NSMenu()
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        recentTranscriptsMenu = NSMenu()
        recentTranscriptsItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        recentTranscriptsItem.submenu = recentTranscriptsMenu
        recentTranscriptsItem.isHidden = true
        menu.addItem(recentTranscriptsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        revealDebugFolderItem = NSMenuItem(
            title: "Reveal Debug Folder",
            action: #selector(revealDebugFolder),
            keyEquivalent: ""
        )
        revealDebugFolderItem.target = self
        revealDebugFolderItem.isHidden = !AppDefaults.debugMode
        menu.addItem(revealDebugFolderItem)

        let quit = NSMenuItem(
            title: "Quit Spokium",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        return menu
    }

    func applyShortcutToMenuItem() {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            toggleMenuItem.setShortcut(shortcut)
        } else {
            toggleMenuItem.keyEquivalent = ""
            toggleMenuItem.keyEquivalentModifierMask = []
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        applyShortcutToMenuItem()
        refreshErrorMenu()
        refreshInputDeviceMenu()
        refreshModelMenu()
        refreshRecentTranscriptsMenu()
        revealDebugFolderItem.isHidden = !AppDefaults.debugMode
        refreshQueueStatus()
        startQueueStatusTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopQueueStatusTimer()
    }

    @objc func toggleRecording() {
        controller.toggle()
    }

    @objc func cancelRecording() {
        controller.cancel()
    }
}
