import SwiftUI

struct IntegrationsTab: View {
    @Environment(RecordingController.self) private var controller
    @AppStorage(DefaultsKey.selectedQuietEndpoint) private var selectedQuietEndpoint = AppDefaults.selectedQuietEndpointDefault
    @State private var quietEndpoints: [QuietEndpoint] = QuietEndpointStore.load()
    @State private var lowerMacVolume = AppDefaults.lowerMacVolumeWhileRecording
    @State private var selection: Set<QuietEndpoint.ID> = []
    @FocusState private var focused: QuietEndpoint.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quiet while recording")
                .font(.headline)

            // Not @AppStorage: 1.5.3 stored a string under the same key, which
            // AppDefaults maps; a Bool @AppStorage would read that as off.
            Toggle("Lower the Mac's volume while recording", isOn: $lowerMacVolume)
                .onChange(of: lowerMacVolume) { _, on in AppDefaults.lowerMacVolumeWhileRecording = on }
                .help("Turns this Mac's sound down while you record and back up when you stop — unless you changed the volume yourself in the meantime.")

            Text("Devices such as a home-made radio. Spokium sends POST when recording starts, repeats it every 20 s, and DELETE when you stop. Nothing about the recording is sent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            EditableList(canRemove: !selection.isEmpty) {
                let endpoint = QuietEndpoint()
                quietEndpoints.append(endpoint)
                selection = [endpoint.id]
                focused = endpoint.id
            } remove: {
                quietEndpoints.removeAll { selection.contains($0.id) }
                selection = []
            } content: {
                List(selection: $selection) {
                    ForEach($quietEndpoints) { $endpoint in
                        HStack(spacing: 8) {
                            TextField("Name", text: $endpoint.name, prompt: Text("Name"))
                                .focused($focused, equals: endpoint.id)
                                .frame(width: 120)
                            TextField("URL", text: $endpoint.url, prompt: Text("http://radio.local/quiet"))
                                .foregroundStyle(endpoint.url.isEmpty || endpoint.validURL != nil ? .primary : Color.red)
                        }
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .tag(endpoint.id)
                    }
                }
            }

            Picker("Quiet:", selection: $selectedQuietEndpoint) {
                Text("None").tag("")
                if !quietEndpoints.isEmpty {
                    Divider()
                }
                ForEach(quietEndpoints) { endpoint in
                    Text(endpoint.name.isEmpty ? endpoint.url : endpoint.name).tag(endpoint.id.uuidString)
                }
            }
            .fixedSize()
            .disabled(quietEndpoints.isEmpty)
        }
        .padding()
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
