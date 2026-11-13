import AppKit
import OSLog

enum PasteResult: Equatable {
    case pasted
    case copied
    case failedNoAccessibility
}

enum Paster {
    private static let logger = Logger(subsystem: "com.spokium.mac", category: "Paster")

    // `copyOnly`: a session ended by sleep or screen lock. Pasting into whatever is in
    // front after unlocking would be a surprise, and the 20 s restore would fire on wake
    // and remove the transcript — so it's just left on the clipboard.
    @discardableResult
    static func paste(_ text: String, copyOnly: Bool = false) async -> PasteResult {
        if copyOnly {
            writeTranscript(text)
            return .copied
        }
        let autoPaste = AppDefaults.autoPaste
        let pasteboard = NSPasteboard.general
        let restorer = ClipboardRestorer.shared

        // Saved in every mode (auto-paste, copy-only, missing permission): the transcript
        // stays on the clipboard for a manual ⌘V, then the previous contents come back.
        let original = AppDefaults.preserveClipboard ? restorer.captureOriginal() : nil
        let changeCount = writeToPasteboard(pasteboard, text: text)
        if let original {
            restorer.scheduleRestore(original, expectedChangeCount: changeCount)
        }

        guard autoPaste else { return .copied }

        if !hasAccessibilityPermission() {
            triggerAccessibilityPrompt()
            logger.error("Auto-paste blocked — Accessibility permission missing; text left on clipboard")
            return .failedNoAccessibility
        }

        guard simulateCommandV() else {
            logger.error("Failed to simulate ⌘V")
            return .failedNoAccessibility
        }
        return .pasted
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        )
    }

    static func requestAccessibilityPermission() {
        triggerAccessibilityPrompt()
    }

    // AXIsProcessTrustedWithOptions(prompt: true) is silently ignored by TCC
    // on modern macOS ("Service kTCCServiceAccessibility does not allow prompting").
    // What actually surfaces the "<App> would like to control this computer"
    // alert and adds the app to Privacy & Security > Accessibility is an
    // attempt to post a synthetic event via CGEvent.post — TCC then publishes
    // a Modify event for kTCCServicePostEvent and launches universalAccessAuthWarn.
    // A null CGEvent is posted so we don't synthesize a real keystroke.
    private static func triggerAccessibilityPrompt() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(source: source) else { return }
        event.post(tap: .cghidEventTap)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func writeToPasteboard(_ pasteboard: NSPasteboard, text: String) -> Int {
        writeTranscript(text, to: pasteboard)
        return pasteboard.changeCount
    }

    // Transcripts stay on this Mac: .currentHostOnly keeps Handoff / Universal Clipboard
    // from offering them to the user's other devices, and the nspasteboard.org markers
    // ask clipboard-history apps (Raycast, Maccy, Paste, Alfred…) not to store them —
    // otherwise every dictation ends up in a history on disk.
    static func writeTranscript(_ text: String, to pasteboard: NSPasteboard = .general) {
        guard AppDefaults.privateClipboard else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return
        }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    // "Stop and send": Return after the paste. The short wait lets the target app
    // insert the pasted text first; explicit empty flags so a still-held ⇧/⌘ from the
    // shortcut doesn't turn it into ⇧Return or ⌘Return.
    static func pressReturn() async {
        try? await Task.sleep(for: .milliseconds(120))
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else { return }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func simulateCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        // key code 9 = 'V'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

}
