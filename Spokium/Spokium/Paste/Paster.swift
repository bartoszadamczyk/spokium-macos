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
        let defaults = UserDefaults.standard
        let autoPaste = defaults.object(forKey: "autoPaste") as? Bool ?? true
        let preserveClipboard = defaults.object(forKey: "preserveClipboard") as? Bool ?? true
        let pasteboard = NSPasteboard.general

        if autoPaste && !hasAccessibilityPermission() {
            _ = writeToPasteboard(pasteboard, text: text)
            triggerAccessibilityPrompt()
            logger.error("Auto-paste blocked — Accessibility permission missing; text left on clipboard")
            return .failedNoAccessibility
        }

        let savedData = preserveClipboard && autoPaste ? savePasteboard(pasteboard) : nil
        let changeCountAfterWrite = writeToPasteboard(pasteboard, text: text)

        guard autoPaste else { return .copied }

        guard simulateCommandV() else {
            logger.error("Failed to simulate ⌘V")
            if let savedData {
                restorePasteboard(pasteboard, saved: savedData, expectedChangeCount: changeCountAfterWrite)
            }
            return .failedNoAccessibility
        }

        if let savedData {
            try? await Task.sleep(for: .milliseconds(150))
            restorePasteboard(pasteboard, saved: savedData, expectedChangeCount: changeCountAfterWrite)
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

    private static func savePasteboard(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        var saved: [[(NSPasteboard.PasteboardType, Data)]] = []
        guard let items = pasteboard.pasteboardItems else { return saved }
        for item in items {
            var itemData: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData.append((type, data))
                }
            }
            saved.append(itemData)
        }
        return saved
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

    private static func restorePasteboard(
        _ pasteboard: NSPasteboard,
        saved: [[(NSPasteboard.PasteboardType, Data)]],
        expectedChangeCount: Int
    ) {
        guard pasteboard.changeCount == expectedChangeCount else { return }
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }

        var newItems: [NSPasteboardItem] = []
        for itemData in saved {
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            newItems.append(item)
        }
        pasteboard.writeObjects(newItems)
    }
}
