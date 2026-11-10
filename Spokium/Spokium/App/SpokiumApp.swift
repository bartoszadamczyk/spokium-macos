import SwiftUI

@main
struct SpokiumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsSceneRoot(controller: appDelegate.controller)
        }
    }
}
