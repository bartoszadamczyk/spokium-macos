import AppKit
import OSLog

enum Paster {
    private static let logger = Logger(subsystem: "com.bartoszadamczyk.Vox", category: "Paster")

    @discardableResult
    static func paste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let savedData = savePasteboard(pasteboard)
        let changeCountAfterWrite = writeToPasteboard(pasteboard, text: text)

        guard simulateCommandV() else {
            logger.error("Failed to simulate ⌘V — check Accessibility permission")
            restorePasteboard(pasteboard, saved: savedData, expectedChangeCount: changeCountAfterWrite)
            return false
        }

        try? await Task.sleep(for: .milliseconds(150))
        restorePasteboard(pasteboard, saved: savedData, expectedChangeCount: changeCountAfterWrite)
        return true
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        )
    }

    static func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
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
