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

    // Cancels a recording or transcription. Only *stored* through KeyboardShortcuts (no
    // handler is registered, so it's never a Carbon hotkey): the recorder and Carbon
    // refuse Shift-only combinations such as ⇧⎋ or ⇧;, which users want here. Matched
    // by key monitors in RecordingMonitors while a session is active instead.
    static let cancelRecording = Self(
        "cancelRecording",
        default: KeyboardShortcuts.Shortcut(.escape, modifiers: [.command])
    )
}
