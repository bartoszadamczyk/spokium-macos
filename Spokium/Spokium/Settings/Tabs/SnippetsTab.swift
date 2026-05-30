import SwiftUI

struct SnippetsTab: View {
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
