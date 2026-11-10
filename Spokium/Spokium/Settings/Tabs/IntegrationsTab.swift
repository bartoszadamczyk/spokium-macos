import SwiftUI

struct IntegrationsTab: View {
    @Environment(RecordingController.self) private var controller
    @AppStorage(DefaultsKey.selectedQuietEndpoint) private var selectedQuietEndpoint = AppDefaults.selectedQuietEndpointDefault
    @State private var quietEndpoints: [QuietEndpoint] = QuietEndpointStore.load()

    var body: some View {
        Form {
            Section {
                if !quietEndpoints.isEmpty {
                    Picker("Quiet:", selection: $selectedQuietEndpoint) {
                        Text("None").tag("")
                        Divider()
                        ForEach(quietEndpoints) { endpoint in
                            Text(endpoint.name.isEmpty ? endpoint.url : endpoint.name).tag(endpoint.id.uuidString)
                        }
                    }
                }
                ForEach($quietEndpoints) { $endpoint in
                    HStack(spacing: 8) {
                        TextField("Name", text: $endpoint.name)
                            .labelsHidden()
                            .frame(width: 110)
                        TextField("URL", text: $endpoint.url, prompt: Text("http://radio.local/quiet"))
                            .labelsHidden()
                            .foregroundStyle(endpoint.url.isEmpty || endpoint.validURL != nil ? .primary : Color.red)
                        Button {
                            quietEndpoints.removeAll { $0.id == endpoint.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add Device") {
                    quietEndpoints.append(QuietEndpoint())
                }
            } header: {
                Text("Quiet while recording")
            } footer: {
                Text("Spokium sends POST when recording starts, repeats it every 20 s, and DELETE when you stop. Nothing about the recording is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: selectedQuietEndpoint) { _, _ in
            controller.quietEndpointChanged()
        }
        .onChange(of: quietEndpoints) { _, newValue in
            QuietEndpointStore.save(newValue)
            if !newValue.contains(where: { $0.id.uuidString == selectedQuietEndpoint }) {
                selectedQuietEndpoint = ""
            }
        }
    }
}
