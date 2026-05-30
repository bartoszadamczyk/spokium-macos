import SwiftUI
import whisper

struct TranscriptionTab: View {
    @AppStorage("selectedLanguage") private var selectedLanguage = "auto"
    @AppStorage("paragraphSplitting") private var paragraphSplitting = true
    @AppStorage("silenceThreshold") private var minSilenceDuration = 3.0
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("preserveClipboard") private var preserveClipboard = true
    @AppStorage("maxRecordingMinutes") private var maxRecordingMinutes: Double = 10.0

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Language:", selection: $selectedLanguage) {
                    Text("Auto-detect").tag("auto")
                    Divider()
                    ForEach(WhisperLanguage.all) { lang in
                        Text(lang.displayName).tag(lang.code)
                    }
                }
                Picker("Auto-stop after:", selection: $maxRecordingMinutes) {
                    Text("1 minute").tag(1.0)
                    Text("2 minutes").tag(2.0)
                    Text("5 minutes").tag(5.0)
                    Text("10 minutes").tag(10.0)
                    Text("30 minutes").tag(30.0)
                    Divider()
                    Text("No limit").tag(0.0)
                }
                Toggle("Split paragraphs on silence", isOn: $paragraphSplitting)
                if paragraphSplitting {
                    HStack {
                        Text("Silence threshold:")
                        Slider(value: $minSilenceDuration, in: 0.5...5.0, step: 0.5)
                        Text("\(minSilenceDuration, specifier: "%.1f")s")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
            Section("Output") {
                Toggle("Auto-paste into focused window", isOn: $autoPaste)
                if autoPaste {
                    Toggle("Restore clipboard after paste", isOn: $preserveClipboard)
                    AccessibilityStatusRow()
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

struct WhisperLanguage: Identifiable {
    let code: String
    let displayName: String
    var id: String { code }

    static let all: [WhisperLanguage] = {
        let maxId = whisper_lang_max_id()
        var langs: [WhisperLanguage] = []
        for i in 0...maxId {
            if let cCode = whisper_lang_str(Int32(i)),
               let cName = whisper_lang_str_full(Int32(i)) {
                let code = String(cString: cCode)
                let name = String(cString: cName)
                langs.append(WhisperLanguage(
                    code: code,
                    displayName: name.prefix(1).uppercased() + name.dropFirst()
                ))
            }
        }
        return langs
    }()
}
