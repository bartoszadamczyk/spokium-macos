import KeyboardShortcuts
import SwiftUI
import whisper

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelTab()
                .tabItem { Label("Model", systemImage: "cpu") }
            DictionaryTab()
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
        }
        .frame(width: 600, height: 400)
    }
}

private struct GeneralTab: View {
    @AppStorage("selectedLanguage") private var selectedLanguage = "auto"
    @AppStorage("paragraphSplitting") private var paragraphSplitting = true
    @AppStorage("silenceThreshold") private var silenceThreshold = 1.5
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("preserveClipboard") private var preserveClipboard = true

    var body: some View {
        Form {
            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Toggle recording:", name: .toggleRecording)
            }
            Section("Language") {
                Picker("Language:", selection: $selectedLanguage) {
                    Text("Auto-detect").tag("auto")
                    Divider()
                    ForEach(WhisperLanguage.all) { lang in
                        Text(lang.displayName).tag(lang.code)
                    }
                }
            }
            Section("Paragraphs") {
                Toggle("Split on silence gaps", isOn: $paragraphSplitting)
                if paragraphSplitting {
                    HStack {
                        Text("Silence threshold:")
                        Slider(value: $silenceThreshold, in: 0.5...5.0, step: 0.5)
                        Text("\(silenceThreshold, specifier: "%.1f")s")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
            Section("Output") {
                Toggle("Auto-paste into focused window", isOn: $autoPaste)
                if autoPaste {
                    Toggle("Restore clipboard after paste", isOn: $preserveClipboard)
                }
            }
        }
        .formStyle(.grouped)
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

private struct ModelTab: View {
    @State private var modelManager = ModelManager()

    private var showError: Binding<Bool> {
        Binding(
            get: { modelManager.lastDownloadError != nil },
            set: { if !$0 { modelManager.dismissDownloadError() } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(WhisperModel.all) { model in
                    ModelRow(model: model, manager: modelManager)
                }
            }
            .listStyle(.inset)

            HStack {
                Button("Show in Finder") {
                    try? ModelLocator.ensureDirectoryExists()
                    NSWorkspace.shared.open(ModelLocator.modelsDirectory)
                }
                .buttonStyle(.link)
                .font(.callout)
                Spacer()
            }
            .padding(.leading, 12)
            .padding(.vertical, 8)
        }
        .alert("Download Failed", isPresented: showError) {
            Button("OK") { modelManager.dismissDownloadError() }
        } message: {
            Text(modelManager.lastDownloadError ?? "")
        }
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    @Bindable var manager: ModelManager
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .fontWeight(.medium)
                    Text(model.sizeLabel)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Text(model.qualityNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let progress = manager.downloads[model.name] {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Button {
                        manager.cancelDownload(model)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else if manager.downloadedNames.contains(model.name) {
                HStack(spacing: 8) {
                    if manager.selectedModelName == model.name {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(controlActiveState == .inactive ? .secondary : .accentColor)
                    } else {
                        Button("Select") {
                            manager.selectedModelName = model.name
                        }
                    }
                    Button {
                        manager.delete(model)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button("Download") {
                    manager.download(model)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DictionaryTab: View {
    @AppStorage("dictionaryEntries") private var entriesText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom names and spellings to bias recognition. One entry per line.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $entriesText)
                .font(.body.monospaced())
                .scrollContentBackground(.visible)
        }
        .padding()
    }
}

