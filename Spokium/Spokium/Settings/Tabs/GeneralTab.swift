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
                KeyboardShortcuts.Recorder("Stop and send:", name: .toggleRecordingAndSend)
                    .help("Starts recordings like the main shortcut; stopping with it also presses Return after the paste — to send a message or submit a prompt.")
                CancelShortcutField()
                    .help("Cancels a recording or transcription. Only watched while one is running. Any combination works, including Shift-only ones such as ⇧⎋. Needs the Accessibility permission to work while another app is in front.")
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
        }
        .formStyle(.grouped)
        .task {
            devices = AudioInputDevice.available()
            defaultInputName = AudioInputDevice.defaultInputName() ?? ""
        }
    }
}
