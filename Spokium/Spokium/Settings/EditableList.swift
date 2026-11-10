import SwiftUI

// The standard macOS editable list: a bordered list with small + / − buttons attached
// to its bottom edge (as in System Settings). The caller supplies the List (with its
// selection); − is disabled until something is selected.
struct EditableList<Content: View, Accessory: View>: View {
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    init(
        canRemove: Bool,
        add: @escaping () -> Void,
        remove: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.canRemove = canRemove
        self.add = add
        self.remove = remove
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 0) {
                barButton("plus", help: "Add", action: add)
                Divider().frame(height: 14)
                barButton("minus", help: "Remove Selected", action: remove)
                    .disabled(!canRemove)
                Spacer()
                accessory
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            .frame(height: 24)
            .buttonStyle(.borderless)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .help(help)
    }
}

#Preview {
    @Previewable @State var items = ["Spokium", "whisper.cpp", "Bartek"]
    @Previewable @State var selection: Set<String> = ["whisper.cpp"]
    EditableList(canRemove: !selection.isEmpty) {
        items.append("New")
    } remove: {
        items.removeAll { selection.contains($0) }
    } content: {
        List(items, id: \.self, selection: $selection) { Text($0) }
    } accessory: {
        Text("\(items.count) entries")
    }
    .padding()
    .frame(width: 560, height: 260)
}
