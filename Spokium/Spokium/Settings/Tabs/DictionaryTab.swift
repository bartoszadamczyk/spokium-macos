import SwiftUI

struct DictionaryTab: View {
    // Still stored as one entry per line, so existing dictionaries load unchanged.
    @AppStorage(DefaultsKey.dictionaryEntries) private var entriesText = AppDefaults.dictionaryEntriesDefault
    @Environment(RecordingController.self) private var controller
    @State private var entries: [Entry] = []
    @State private var selection: Set<Entry.ID> = []
    @FocusState private var focused: Entry.ID?
    @State private var tokenCount: Int?
    @AppStorage(DefaultsKey.liveTranscription) private var liveTranscription = AppDefaults.liveTranscriptionDefault

    // Whisper keeps the last 224 prompt tokens. In live mode the prompt also carries
    // ~200 characters (~50 tokens) of the previous text after the dictionary, so beyond
    // ~174 the first entries are silently dropped.
    private var tokenBudget: Int { liveTranscription ? 174 : 224 }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    private var prompt: String? {
        DictionaryPromptBuilder.prompt(from: entriesText)
    }

    private var entryCount: Int {
        entries.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom names and spellings to bias recognition.")
                .font(.callout)
                .foregroundStyle(.secondary)

            EditableList(canRemove: !selection.isEmpty) {
                let entry = Entry(text: "")
                entries.append(entry)
                selection = [entry.id]
                focused = entry.id
            } remove: {
                entries.removeAll { selection.contains($0.id) }
                selection = []
            } content: {
                List(selection: $selection) {
                    ForEach($entries) { $entry in
                        TextField("Entry", text: $entry.text, prompt: Text("Name or spelling"))
                            .textFieldStyle(.plain)
                            .labelsHidden()
                            .focused($focused, equals: entry.id)
                            .tag(entry.id)
                    }
                }
            } accessory: {
                if let tokenCount, prompt != nil {
                    Text("\(entryCount) \(entryCount == 1 ? "entry" : "entries") · \(tokenCount) / \(tokenBudget) tokens")
                        .foregroundStyle(tokenCount > tokenBudget - 24 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                } else {
                    Text("\(entryCount) \(entryCount == 1 ? "entry" : "entries")")
                }
            }

            if let tokenCount, tokenCount > tokenBudget - 24 {
                Text(liveTranscription
                     ? "Approaching the limit — with “Transcribe while recording” on, the previous sentence shares the prompt, so the first entries may be dropped."
                     : "Approaching the token limit — entries may be truncated.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .onAppear {
            entries = entriesText.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { Entry(text: $0) }
        }
        .onChange(of: entries) { _, newValue in
            entriesText = newValue.map(\.text).joined(separator: "\n")
        }
        .task(id: prompt) {
            guard let prompt else {
                tokenCount = nil
                return
            }
            tokenCount = await controller.countDictionaryTokens(prompt)
        }
    }
}
