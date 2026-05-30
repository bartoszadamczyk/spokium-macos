import SwiftUI

struct DictionaryTab: View {
    @AppStorage("dictionaryEntries") private var entriesText = ""
    @Environment(RecordingController.self) private var controller
    @State private var tokenCount: Int?

    private var prompt: String? {
        DictionaryPromptBuilder.prompt(from: entriesText)
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
