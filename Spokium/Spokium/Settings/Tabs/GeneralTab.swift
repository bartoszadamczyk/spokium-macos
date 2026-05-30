import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @Environment(RecordingController.self) private var controller
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("selectedInputDevice") private var selectedInputDevice = ""
    @AppStorage("pushToRecord") private var pushToRecord = false
    @AppStorage("playSounds") private var playSounds = false
    @AppStorage("autoSplitMinutes") private var autoSplitMinutes: Double = 5
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
                Picker("Auto-split every:", selection: $autoSplitMinutes) {
                    Text("Off").tag(0.0)
                    Text("1 min").tag(1.0)
                    Text("2 min").tag(2.0)
                    Text("3 min").tag(3.0)
                    Text("5 min").tag(5.0)
                    Text("10 min").tag(10.0)
                    Text("15 min").tag(15.0)
                    Text("20 min").tag(20.0)
                    Text("30 min").tag(30.0)
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
