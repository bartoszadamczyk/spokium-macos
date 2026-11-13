import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // The dev build (com.spokium.mac.dev) runs alongside production, and two apps
    // can't both register the same Carbon hotkey — so it adds ⌃ to both defaults.
    #if DEBUG
    private static let defaultToggle = KeyboardShortcuts.Shortcut(.semicolon, modifiers: [.control, .command])
    private static let defaultSend = KeyboardShortcuts.Shortcut(.semicolon, modifiers: [.control, .shift, .command])
    #else
    private static let defaultToggle = KeyboardShortcuts.Shortcut(.semicolon, modifiers: [.command])
    private static let defaultSend = KeyboardShortcuts.Shortcut(.semicolon, modifiers: [.shift, .command])
    #endif

    static let toggleRecording = Self(
        "toggleRecording",
        default: defaultToggle
    )

    // Same as toggleRecording, but stopping with it also presses Return after the
    // paste (send a message, submit a prompt). The choice is made at stop time.
    static let toggleRecordingAndSend = Self(
        "toggleRecordingAndSend",
        default: defaultSend
    )

    // Cancels a recording or transcription. A Carbon hotkey enabled only while a session
    // is active, so the keys stay free for other apps the rest of the time. Not a key
    // monitor: inside the sandbox a global monitor never sees keys sent to other apps
    // (it only worked while Spokium's own window was focused). Carbon can't do
    // Shift-only combinations, hence ⌘⎋ rather than ⇧⎋.
    static let cancelRecording = Self(
        "cancelRecording",
        default: KeyboardShortcuts.Shortcut(.escape, modifiers: [.command])
    )
}
