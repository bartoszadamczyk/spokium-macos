import AppKit
import OSLog

enum PasteResult: Equatable {
    case pasted
    case copied
    case failedNoAccessibility
}

enum Paster {
    private static let logger = Logger(subsystem: "com.spokium.mac", category: "Paster")

    @discardableResult
    static func paste(_ text: String) async -> PasteResult {
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
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
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
