import SwiftUI

struct SnippetsTab: View {
    @State private var snippets: [Snippet] = SnippetStore.load()
    @State private var selection: Set<Snippet.ID> = []
    @FocusState private var focused: Snippet.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replace spoken phrases with text. Matches whole words case-insensitively. Type \\n in a replacement for a line break.")
                .font(.callout)
                .foregroundStyle(.secondary)

            EditableList(canRemove: !selection.isEmpty) {
                let snippet = Snippet()
                snippets.append(snippet)
                selection = [snippet.id]
                focused = snippet.id
            } remove: {
                snippets.removeAll { selection.contains($0.id) }
                selection = []
            } content: {
                List(selection: $selection) {
                    ForEach($snippets) { $snippet in
                        HStack(spacing: 8) {
                            TextField("Trigger", text: $snippet.trigger, prompt: Text("Spoken phrase"))
                                .focused($focused, equals: snippet.id)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            TextField("Replacement", text: $snippet.replacement, prompt: Text("Replacement"))
                        }
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .tag(snippet.id)
                    }
                }
            } accessory: {
                Text("\(snippets.count) \(snippets.count == 1 ? "snippet" : "snippets")")
            }
        }
        .padding()
        .onChange(of: snippets) { _, newValue in
            SnippetStore.save(newValue)
        }
    }
}
