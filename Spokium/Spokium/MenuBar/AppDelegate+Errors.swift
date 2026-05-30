import AppKit

extension AppDelegate {
    func observeErrors() {
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

    func observePersistentError() {
        withObservationTracking { [weak self] in
            _ = self?.controller.persistentError
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshErrorMenu()
                self.observePersistentError()
            }
        }
    }

    func refreshErrorMenu() {
        guard let error = controller.persistentError else {
            errorRowItem.isHidden = true
            errorActionItem.isHidden = true
            disableAutoPasteItem.isHidden = true
            dismissErrorItem.isHidden = true
            errorSeparator.isHidden = true
            return
        }
        errorRowItem.title = error.menuMessage
        errorRowItem.isHidden = false
        dismissErrorItem.isHidden = false
        errorSeparator.isHidden = false
        let isAccessibility = error == .noAccessibility
        errorActionItem.isHidden = !isAccessibility
        disableAutoPasteItem.isHidden = !isAccessibility
    }

    func showErrorAlert(_ error: RecordingError) {
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
            alert.informativeText = "Spokium needs microphone access to record audio. Grant permission in System Settings → Privacy & Security → Microphone."
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
            alert.informativeText = "Spokium couldn't paste — Accessibility access is missing. Your transcript is on the clipboard, so you can paste it manually with ⌘V. To enable auto-paste, grant access in System Settings → Privacy & Security → Accessibility."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func dismissPersistentError() {
        controller.dismissPersistentError()
    }

    @objc func openAccessibilitySettings() {
        Paster.openAccessibilitySettings()
    }

    @objc func disableAutoPaste() {
        UserDefaults.standard.set(false, forKey: "autoPaste")
        controller.dismissPersistentError()
    }
}
