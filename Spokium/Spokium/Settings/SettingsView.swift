import AppKit
import SwiftUI

struct SettingsSceneRoot: View {
    let controller: RecordingController

    var body: some View {
        SettingsView()
            .environment(controller)
            .modifier(DevBuildBanner())
    }
}

// Marks the dev build's settings so they aren't mistaken for production's — the two
// apps have separate defaults, models and dictionary.
private struct DevBuildBanner: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Text("DEV BUILD · \(Bundle.main.bundleIdentifier ?? "")")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.orange)
                .foregroundStyle(.black)
        }
        #else
        content
        #endif
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
