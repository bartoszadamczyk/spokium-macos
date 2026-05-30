import AppKit
import SwiftUI

struct SettingsSceneRoot: View {
    var body: some View {
        if let controller = (NSApp.delegate as? AppDelegate)?.controller {
            SettingsView()
                .environment(controller)
        } else {
            Text("Settings unavailable")
                .foregroundStyle(.secondary)
                .frame(width: 600, height: 400)
        }
    }
}

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
