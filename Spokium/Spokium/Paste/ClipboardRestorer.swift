import AppKit

// Puts the user's previous clipboard back a while after a transcript was placed on it.
//
// The delay is long on purpose: the transcript stays available for a manual ⌘V when the
// auto-paste landed in the wrong window, or when auto-paste is off. Rules:
//   - If anything else is copied in the meantime (changeCount moved), that copy wins and
//     nothing is restored.
//   - A new transcript before the restore fires keeps the *original* clipboard pending,
//     rather than "restoring" the previous transcript.
//   - restoreNow() lets quit put the clipboard back immediately.
@MainActor
final class ClipboardRestorer {
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    static let shared = ClipboardRestorer(pasteboard: .general, delay: .seconds(20))

    private let pasteboard: NSPasteboard
    private let delay: Duration
    private var pending: (snapshot: Snapshot, expectedChangeCount: Int)?
    private var task: Task<Void, Never>?

    init(pasteboard: NSPasteboard, delay: Duration) {
        self.pasteboard = pasteboard
        self.delay = delay
    }

    var hasPendingRestore: Bool { pending != nil }

    // The clipboard to restore later: the still-pending original if our previous
    // transcript is untouched on the pasteboard, otherwise whatever is there now.
    func captureOriginal() -> Snapshot {
        defer { cancelPending() }
        if let pending, pasteboard.changeCount == pending.expectedChangeCount {
            return pending.snapshot
        }
        return Self.snapshot(of: pasteboard)
    }

    func scheduleRestore(_ snapshot: Snapshot, expectedChangeCount: Int) {
        cancelPending()
        pending = (snapshot, expectedChangeCount)
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.restoreNow()
        }
    }

    func restoreNow() {
        guard let pending else { return }
        cancelPending()
        guard pasteboard.changeCount == pending.expectedChangeCount else { return }
        pasteboard.clearContents()
        let items = pending.snapshot.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func cancelPending() {
        task?.cancel()
        task = nil
        pending = nil
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }
}
