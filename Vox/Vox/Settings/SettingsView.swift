import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import whisper

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionTab()
                .tabItem { Label("Transcription", systemImage: "waveform") }
            ModelTab()
                .tabItem { Label("Model", systemImage: "cpu") }
            DictionaryTab()
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
            SnippetsTab()
                .tabItem { Label("Snippets", systemImage: "text.append") }
        }
        .frame(width: 600, height: 400)
    }
}

private struct GeneralTab: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("selectedInputDevice") private var selectedInputDevice = ""
    @AppStorage("pushToRecord") private var pushToRecord = false
    @State private var devices: [AudioInputDevice] = []
    @State private var defaultInputName: String = ""

    var body: some View {
        Form {
            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Shortcut:", name: .toggleRecording)
                Toggle("Push to record (hold shortcut while speaking)", isOn: $pushToRecord)
            }
            Section("Audio Input") {
                Picker("Input device:", selection: $selectedInputDevice) {
                    Text(defaultInputName.isEmpty ? "System Default" : "System Default (\(defaultInputName))").tag("")
                    if !devices.isEmpty {
                        Divider()
                        ForEach(devices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .task {
            devices = AudioInputDevice.available()
            defaultInputName = AudioInputDevice.defaultInputName() ?? ""
        }
    }
}

private struct TranscriptionTab: View {
    @AppStorage("selectedLanguage") private var selectedLanguage = "auto"
    @AppStorage("paragraphSplitting") private var paragraphSplitting = true
    @AppStorage("silenceThreshold") private var silenceThreshold = 1.5
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("preserveClipboard") private var preserveClipboard = true

    var body: some View {
        Form {
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
    @Environment(RecordingController.self) private var controller
    @State private var tokenCount: Int?

    private var prompt: String? {
        let entries = entriesText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return nil }
        return entries.joined(separator: ", ")
    }

    private var entryCount: Int {
        entriesText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom names and spellings to bias recognition. One entry per line.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $entriesText)
                .font(.body.monospaced())
                .scrollContentBackground(.visible)
            HStack {
                if let tokenCount, prompt != nil {
                    Text("\(entryCount) \(entryCount == 1 ? "entry" : "entries") · \(tokenCount) / 224 tokens")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(entryCount) \(entryCount == 1 ? "entry" : "entries")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let tokenCount, tokenCount > 200 {
                    Text("Approaching token limit — entries may be truncated")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .task(id: prompt) {
            guard let prompt else {
                tokenCount = nil
                return
            }
            tokenCount = await controller.countDictionaryTokens(prompt)
        }
    }
}

private struct SnippetsTab: View {
    @State private var snippets: [Snippet] = SnippetStore.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replace spoken phrases with text. Matches whole words case-insensitively.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach($snippets) { $snippet in
                    HStack(spacing: 8) {
                        TextField("Trigger", text: $snippet.trigger)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("Replacement", text: $snippet.replacement)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            snippets.removeAll { $0.id == snippet.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Button("Add Snippet") {
                    snippets.append(Snippet())
                }
                Spacer()
                Text("\(snippets.count) \(snippets.count == 1 ? "snippet" : "snippets")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onChange(of: snippets) { _, newValue in
            SnippetStore.save(newValue)
        }
    }
}

