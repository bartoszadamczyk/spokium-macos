import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @Environment(RecordingController.self) private var controller
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(DefaultsKey.selectedInputDevice) private var selectedInputDevice = AppDefaults.selectedInputDeviceDefault
    @AppStorage(DefaultsKey.pushToRecord) private var pushToRecord = AppDefaults.pushToRecordDefault
    @AppStorage(DefaultsKey.playSounds) private var playSounds = AppDefaults.playSoundsDefault
    @AppStorage(DefaultsKey.maxRecordingMinutes) private var maxRecordingMinutes = AppDefaults.maxRecordingMinutesDefault
    @AppStorage(DefaultsKey.selectedQuietEndpoint) private var selectedQuietEndpoint = AppDefaults.selectedQuietEndpointDefault
    @State private var quietEndpoints: [QuietEndpoint] = QuietEndpointStore.load()
    @State private var devices: [AudioInputDevice] = []
    @State private var defaultInputName: String = ""

    var body: some View {
        Form {
            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("Recording") {
                KeyboardShortcuts.Recorder("Shortcut:", name: .toggleRecording)
                Toggle("Push to record (hold shortcut while speaking)", isOn: $pushToRecord)
                Picker("Input device:", selection: $selectedInputDevice) {
                    Text(defaultInputName.isEmpty ? "System Default" : "System Default (\(defaultInputName))").tag("")
                    if !devices.isEmpty {
                        Divider()
                        ForEach(devices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
                .disabled(controller.state == .starting || controller.state == .finishing)
                .onChange(of: selectedInputDevice) { _, newUID in
                    // Trigger seamless device handoff when changed mid-recording
                    controller.switchInputDevice(uid: newUID)
                }
                Picker("Auto-stop after:", selection: $maxRecordingMinutes) {
                    Text("10 minutes").tag(10.0)
                    Text("20 minutes").tag(20.0)
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                    Divider()
                    Text("No limit").tag(0.0)
                }
                .onAppear {
                    // A value saved by an older version (1/2/5 min) would leave the picker blank.
                    let normalized = AppDefaults.normalizedMaxRecordingMinutes(maxRecordingMinutes)
                    if normalized != maxRecordingMinutes { maxRecordingMinutes = normalized }
                }
                Toggle("Play sound effects", isOn: $playSounds)
            }
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
        .onChange(of: selectedQuietEndpoint) { _, _ in
            controller.quietEndpointChanged()
        }
        .onChange(of: quietEndpoints) { _, newValue in
            QuietEndpointStore.save(newValue)
            if !newValue.contains(where: { $0.id.uuidString == selectedQuietEndpoint }) {
                selectedQuietEndpoint = ""
            }
        }
        .formStyle(.grouped)
        .task {
            devices = AudioInputDevice.available()
            defaultInputName = AudioInputDevice.defaultInputName() ?? ""
        }
    }
}
