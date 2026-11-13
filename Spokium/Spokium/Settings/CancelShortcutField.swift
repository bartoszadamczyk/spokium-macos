import AppKit
import KeyboardShortcuts
import SwiftUI

// KeyboardShortcuts.Recorder refuses Shift-only combinations (it's built for Carbon
// hotkeys, where they don't work). The cancel shortcut is matched by key monitors, so
// any combination works; this captures the next key press itself.
struct CancelShortcutField: View {
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .cancelRecording)
    @State private var isCapturing = false
    @State private var monitor: Any?

    private var isDefault: Bool { shortcut == KeyboardShortcuts.Name.cancelRecording.defaultShortcut }

    var body: some View {
        LabeledContent("Cancel shortcut:") {
            HStack(spacing: 6) {
                Button(isCapturing ? "Press keys…" : (shortcut?.description ?? "None")) {
                    isCapturing ? stopCapturing() : startCapturing()
                }
                .frame(minWidth: 90)
                if !isDefault, !isCapturing {
                    Button("Reset") {
                        KeyboardShortcuts.reset(.cancelRecording)
                        shortcut = KeyboardShortcuts.getShortcut(for: .cancelRecording)
                    }
                    .controlSize(.small)
                }
            }
        }
        .onDisappear(perform: stopCapturing)
    }

    private func startCapturing() {
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // A bare letter or digit would cancel the recording while typing.
            let modifiers = RecordingMonitors.relevantModifiers(of: event)
            let isPlainCharacter = modifiers.isEmpty
                && event.charactersIgnoringModifiers?.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) == true
            guard !isPlainCharacter, let captured = KeyboardShortcuts.Shortcut(event: event) else {
                NSSound.beep()
                return nil
            }
            KeyboardShortcuts.setShortcut(captured, for: .cancelRecording)
            shortcut = captured
            stopCapturing()
            return nil
        }
    }

    private func stopCapturing() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isCapturing = false
    }
}
