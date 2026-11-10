import SwiftUI
import whisper

struct TranscriptionTab: View {
    @AppStorage(DefaultsKey.selectedLanguage) private var selectedLanguage = AppDefaults.selectedLanguageDefault
    @AppStorage(DefaultsKey.paragraphSplitting) private var paragraphSplitting = AppDefaults.paragraphSplittingDefault
    @AppStorage(DefaultsKey.silenceThreshold) private var minSilenceDuration = AppDefaults.silenceThresholdDefault
    @AppStorage(DefaultsKey.liveTranscription) private var liveTranscription = AppDefaults.liveTranscriptionDefault
    @AppStorage(DefaultsKey.autoDetectLanguages) private var autoDetectLanguages = AppDefaults.autoDetectLanguagesDefault
    @State private var languageUsage: [String: Int] = [:]

    private var selectedDetectCodes: [String] {
        autoDetectLanguages.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    // One menu drives both stored keys: nothing ticked = auto-detect anything; one
    // language = forced; several = auto-detect with that list as the allowed set.
    private var chosenLanguages: [String] {
        selectedLanguage == "auto" ? selectedDetectCodes : [selectedLanguage]
    }

    private func setChosenLanguages(_ codes: [String]) {
        selectedLanguage = codes.count == 1 ? codes[0] : "auto"
        autoDetectLanguages = codes.joined(separator: ",")
    }

    private var languageLabel: String {
        let codes = chosenLanguages
        guard !codes.isEmpty else { return "Any language" }
        let names = codes.compactMap { code in WhisperLanguage.all.first { $0.code == code }?.displayName }
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

    private func languageBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { chosenLanguages.contains(code) },
            set: { isOn in
                var codes = chosenLanguages.filter { $0 != code }
                if isOn { codes.append(code) }
                setChosenLanguages(codes)
            }
        )
    }

    var body: some View {
        Form {
            Section("Language") {
                LabeledContent("Language:") {
                    Menu(languageLabel) {
                        Button("Any language") { setChosenLanguages([]) }
                        Divider()
                        ForEach(WhisperLanguage.menuOrder) { lang in
                            Toggle(lang.displayName, isOn: languageBinding(for: lang.code))
                        }
                    }
                    .fixedSize()
                }
                .help("Any language: detected freely. One language: everything is transcribed as that language (other languages get translated into it). Two or more: detection stays free, so mixed speech stays mixed, but a phrase detected as a language outside your list is redone in your main language.")
                // A single language at 100% says nothing.
                if languageUsage.count > 1 {
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
            Section("Processing") {
                Toggle(isOn: $liveTranscription) {
                    Text("Transcribe while recording")
                    Text("Processes speech in short chunks as you talk, so long recordings paste almost immediately.")
                }
                Toggle("Split paragraphs on silence", isOn: $paragraphSplitting)
                if paragraphSplitting {
                    HStack {
                        Text("Silence threshold:")
                        Slider(value: $minSilenceDuration, in: 0.5...6.0, step: 0.5)
                        Text("\(minSilenceDuration, specifier: "%.1f")s")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            languageUsage = LanguageUsageStore.all()
            // Older settings could hold auto-detect with a one-language list; the menu shows
            // that as a single choice, so make it behave like one.
            if selectedLanguage == "auto", selectedDetectCodes.count == 1 {
                setChosenLanguages(selectedDetectCodes)
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

    // English first (the most common pick), then alphabetical by name.
    static let menuOrder: [WhisperLanguage] = all.sorted { lhs, rhs in
        if lhs.code == "en" || rhs.code == "en" { return lhs.code == "en" }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}
