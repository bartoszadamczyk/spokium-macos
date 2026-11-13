import AppKit

extension AppDelegate {
    func refreshInputDeviceMenu() {
        inputDeviceMenu.removeAllItems()
        let selectedUID = AppDefaults.selectedInputDevice
        // Allow switching device while recording (seamless handoff); lock only during start/finish
        let locked = controller.state == .starting || controller.state == .finishing

        let defaultName = AudioInputDevice.defaultInputName() ?? "Unknown"
        let defaultItem = NSMenuItem(title: "System Default (\(defaultName))", action: #selector(selectInputDevice(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = "" as String
        defaultItem.state = selectedUID.isEmpty ? .on : .off
        defaultItem.isEnabled = !locked
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
            item.isEnabled = !locked
            inputDeviceMenu.addItem(item)
        }
    }

    @objc func selectInputDevice(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        controller.switchInputDevice(uid: uid)
    }

    func refreshModelMenu() {
        modelMenu.removeAllItems()
        let manager = ModelManager()
        let downloaded = WhisperModel.all.filter { manager.downloadedNames.contains($0.name) }

        if downloaded.isEmpty {
            let empty = NSMenuItem(title: "No models downloaded", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            modelMenu.addItem(empty)
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
        }
    }

    @objc func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let manager = ModelManager()
        manager.selectedModelName = name
    }

    func refreshRecentTranscriptsMenu() {
        recentTranscriptsItem.isHidden = !AppDefaults.keepRecentTranscripts
        guard AppDefaults.keepRecentTranscripts else { return }

        // Prune expired entries lazily on open so the user never sees a stale list.
        controller.history.prune()
        recentTranscriptsMenu.removeAllItems()
        let entries = controller.history.entries

        if entries.isEmpty {
            let empty = NSMenuItem(title: "No recent transcripts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentTranscriptsMenu.addItem(empty)
        } else {
            for entry in entries {
                let item = NSMenuItem(
                    title: entry.preview,
                    action: #selector(copyRecentTranscript(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.text
                item.toolTip = entry.text
                recentTranscriptsMenu.addItem(item)
            }
        }

        recentTranscriptsMenu.addItem(.separator())
        let clear = NSMenuItem(
            title: "Clear History",
            action: #selector(clearRecentTranscripts),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = !entries.isEmpty
        recentTranscriptsMenu.addItem(clear)
    }

    @objc func copyRecentTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        Paster.writeTranscript(text, to: pasteboard)
        recordingOverlay.showFeedback(.copied, controller: controller)
    }

    @objc func clearRecentTranscripts() {
        controller.history.clear()
    }

    @objc func revealDebugFolder() {
        DebugRecordingStore.revealInFinder()
    }

    // A multi-select list: "Lower Mac Volume", then every device from Settings →
    // Integrations, each with its own tick.
    func refreshQuietMenu() {
        quietMenu.removeAllItems()
        quietItem.isHidden = false

        let lowerItem = NSMenuItem(title: "Lower Mac Volume", action: #selector(toggleLowerMacVolume(_:)), keyEquivalent: "")
        lowerItem.target = self
        lowerItem.state = AppDefaults.lowerMacVolumeWhileRecording ? .on : .off
        quietMenu.addItem(lowerItem)

        let endpoints = QuietEndpointStore.load()
        guard !endpoints.isEmpty else { return }
        quietMenu.addItem(.separator())
        for endpoint in endpoints {
            let item = NSMenuItem(title: endpoint.displayName, action: #selector(toggleQuietEndpoint(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = endpoint.id
            item.state = endpoint.enabled ? .on : .off
            quietMenu.addItem(item)
        }
    }

    @objc func toggleLowerMacVolume(_ sender: NSMenuItem) {
        AppDefaults.lowerMacVolumeWhileRecording.toggle()
    }

    @objc func toggleQuietEndpoint(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? QuietEndpoint.ID else { return }
        QuietEndpointStore.setEnabled(sender.state != .on, id: id)
        controller.quietEndpointsChanged()
    }
}
