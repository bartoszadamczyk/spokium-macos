import SwiftUI
import whisper

struct TranscriptionTab: View {
    @AppStorage(DefaultsKey.selectedLanguage) private var selectedLanguage = AppDefaults.selectedLanguageDefault
    @AppStorage(DefaultsKey.paragraphSplitting) private var paragraphSplitting = AppDefaults.paragraphSplittingDefault
    @AppStorage(DefaultsKey.silenceThreshold) private var minSilenceDuration = AppDefaults.silenceThresholdDefault
    @AppStorage(DefaultsKey.autoPaste) private var autoPaste = AppDefaults.autoPasteDefault
    @AppStorage(DefaultsKey.preserveClipboard) private var preserveClipboard = AppDefaults.preserveClipboardDefault
    @AppStorage(DefaultsKey.maxRecordingMinutes) private var maxRecordingMinutes = AppDefaults.maxRecordingMinutesDefault
    @AppStorage(DefaultsKey.liveTranscription) private var liveTranscription = AppDefaults.liveTranscriptionDefault
    @AppStorage(DefaultsKey.autoDetectLanguages) private var autoDetectLanguages = AppDefaults.autoDetectLanguagesDefault
    @State private var languageUsage: [String: Int] = [:]

    private var selectedDetectCodes: [String] {
        autoDetectLanguages.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    private var detectAmongLabel: String {
        let codes = selectedDetectCodes
        guard !codes.isEmpty else { return "Any language" }
        let names = WhisperLanguage.all.filter { codes.contains($0.code) }.map(\.displayName)
        return names.formatted(.list(type: .and))
    }

    private var usageSummary: String {
        LanguageUsageStore.shares(languageUsage)
            .prefix(4)
            .map { share in
                let name = WhisperLanguage.all.first { $0.code == share.code }?.displayName ?? share.code
                return "\(name) \(share.fraction.formatted(.percent.precision(.fractionLength(0))))"
            }
            .joined(separator: " · ")
    }

    private func detectBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selectedDetectCodes.contains(code) },
            set: { isOn in
                var codes = selectedDetectCodes.filter { $0 != code }
                if isOn { codes.append(code) }
                autoDetectLanguages = codes.joined(separator: ",")
            }
        )
    }

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
                if selectedLanguage == "auto" {
                    LabeledContent("Languages I speak:") {
                        Menu(detectAmongLabel) {
                            Button("Any language") { autoDetectLanguages = "" }
                            Divider()
                            ForEach(WhisperLanguage.all) { lang in
                                Toggle(lang.displayName, isOn: detectBinding(for: lang.code))
                            }
                        }
                        .fixedSize()
                    }
                    .help("Auto-detect still runs freely, so mixed-language speech stays mixed. Only when it detects a language outside this list (typical for short or quiet phrases) is that part re-transcribed in the language you've used most in the current recording.")
                    if !languageUsage.isEmpty {
                        LabeledContent("Your usage:") {
                            HStack {
                                Text(usageSummary)
                                    .foregroundStyle(.secondary)
                                Button("Reset") {
                                    LanguageUsageStore.reset()
                                    languageUsage = [:]
                                }
                                .controlSize(.small)
                            }
                        }
                        .help("Characters transcribed per detected language, across all recordings. Only counts are stored — never text. Used as the fallback language when a recording has no history yet.")
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
                Toggle(isOn: $liveTranscription) {
                    Text("Transcribe while recording")
                    Text("Processes speech in short chunks as you talk, so long recordings paste almost immediately.")
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
        .onAppear { languageUsage = LanguageUsageStore.all() }
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
