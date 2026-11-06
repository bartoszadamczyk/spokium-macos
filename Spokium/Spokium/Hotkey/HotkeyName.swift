import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // The dev build (com.spokium.mac.dev) runs alongside production, and two apps
    // can't both register the same Carbon hotkey — so it defaults to ⌃⌥Space.
    #if DEBUG
    private static let defaultToggle = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .option])
    #else
    private static let defaultToggle = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
    #endif

    static let toggleRecording = Self(
        "toggleRecording",
        default: defaultToggle
    )
}
