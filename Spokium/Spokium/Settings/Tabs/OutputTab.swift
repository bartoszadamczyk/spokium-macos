import SwiftUI

struct OutputTab: View {
    @Environment(RecordingController.self) private var controller
    @AppStorage(DefaultsKey.autoPaste) private var autoPaste = AppDefaults.autoPasteDefault
    @AppStorage(DefaultsKey.preserveClipboard) private var preserveClipboard = AppDefaults.preserveClipboardDefault
    @AppStorage(DefaultsKey.keepRecentTranscripts) private var keepRecentTranscripts = AppDefaults.keepRecentTranscriptsDefault
    @AppStorage(DefaultsKey.privateClipboard) private var privateClipboard = AppDefaults.privateClipboardDefault

    var body: some View {
        Form {
            Section("Paste") {
                Toggle("Auto-paste into focused window", isOn: $autoPaste)
                if autoPaste {
                    AccessibilityStatusRow()
                }
            }
            Section("Clipboard") {
                Toggle(isOn: $preserveClipboard) {
                    Text("Restore clipboard 5 s after transcribing")
                    Text("The transcript stays on the clipboard long enough to paste it manually, then your previous clipboard comes back — unless you copy something else first.")
                }
                Toggle(isOn: $privateClipboard) {
                    Text("Keep transcripts private")
                    Text("Clipboard-history apps don't save them, and they aren't offered to your other devices via Handoff.")
                }
                Toggle("Keep recent transcripts (5 min, memory only)", isOn: $keepRecentTranscripts)
                    .onChange(of: keepRecentTranscripts) { _, newValue in
                        if !newValue { controller.history.clear() }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

struct AccessibilityStatusRow: View {
    @State private var hasPermission = Paster.hasAccessibilityPermission()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(hasPermission ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(hasPermission
                    ? "Accessibility permission granted — paste is ready."
                    : "Accessibility permission required to paste.")
                    .font(.callout)
                if !hasPermission {
                    Text("Without it, Spokium can only copy to the clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !hasPermission {
                Button("Request Permission") {
                    Paster.requestAccessibilityPermission()
                }
            }
        }
        .task {
            while !Task.isCancelled {
                hasPermission = Paster.hasAccessibilityPermission()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}
