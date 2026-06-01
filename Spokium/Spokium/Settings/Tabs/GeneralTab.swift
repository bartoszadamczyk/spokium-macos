import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @Environment(RecordingController.self) private var controller
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(DefaultsKey.selectedInputDevice) private var selectedInputDevice = AppDefaults.selectedInputDeviceDefault
    @AppStorage(DefaultsKey.pushToRecord) private var pushToRecord = AppDefaults.pushToRecordDefault
    @AppStorage(DefaultsKey.playSounds) private var playSounds = AppDefaults.playSoundsDefault
    @AppStorage(DefaultsKey.keepRecentTranscripts) private var keepRecentTranscripts = AppDefaults.keepRecentTranscriptsDefault
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
                Toggle("Play sound effects", isOn: $playSounds)
                Toggle("Keep recent transcripts (5 min, memory only)", isOn: $keepRecentTranscripts)
                    .onChange(of: keepRecentTranscripts) { _, newValue in
                        if !newValue { controller.history.clear() }
                    }
            }
        }
        .formStyle(.grouped)
        .task {
            devices = AudioInputDevice.available()
            defaultInputName = AudioInputDevice.defaultInputName() ?? ""
        }
    }
}
