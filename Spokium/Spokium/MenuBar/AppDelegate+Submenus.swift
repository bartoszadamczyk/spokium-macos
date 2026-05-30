import AppKit

extension AppDelegate {
    func refreshInputDeviceMenu() {
        inputDeviceMenu.removeAllItems()
        let selectedUID = UserDefaults.standard.string(forKey: "selectedInputDevice") ?? ""
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

    @objc func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let manager = ModelManager()
        manager.selectedModelName = name
    }
}
