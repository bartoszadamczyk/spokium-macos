import KeyboardShortcuts
import SwiftUI

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
        .frame(width: 480, height: 320)
    }
}

private struct GeneralTab: View {
    var body: some View {
        Form {
            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Toggle recording:", name: .toggleRecording)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelTab: View {
    @State private var modelManager = ModelManager()

    var body: some View {
        List {
            ForEach(WhisperModel.all) { model in
                ModelRow(model: model, manager: modelManager)
            }
        }
        .listStyle(.inset)
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
    var body: some View {
        ContentUnavailableView(
            "Dictionary",
            systemImage: "text.book.closed",
            description: Text("Custom names and spellings to bias recognition")
        )
    }
}
