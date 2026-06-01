# AGENTS.md

Context for AI coding assistants working in this repo.

## What this project is

A native macOS menu-bar dictation app. Tap a global hotkey to start recording, tap again to stop → audio is transcribed and pasted into the focused window. Transcription is done locally via whisper.cpp. See `README.md` for the full goals list.

## Tech choices (locked in)

- **Language:** Swift 6.0 with strict concurrency, default `@MainActor` isolation.
- **UI:** SwiftUI for the settings window. AppKit for `NSStatusItem` menu bar, `NSPanel` overlay HUD, `NSHostingSceneRepresentation` to bridge Settings scene opening from AppKit.
- **Min target:** macOS 26.3. Required for `NSHostingSceneRepresentation` used to open Settings from AppKit menu bar code.
- **Sandboxed.** The app runs under App Sandbox. Accessibility-driven ⌘V, global hotkeys, and microphone all work in sandbox once the user grants the relevant permissions.
- **IDE:** Xcode. The project is an Xcode app target, not a SwiftPM executable, because we need an `.app` bundle, `Info.plist`, entitlements, and a menu-bar `LSUIElement` flag.
- **Whisper integration:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) via `Spokium/Frameworks/whisper.xcframework`. In this checkout the XCFramework is present and tracked in Git, but it is still a rebuildable artifact from upstream `whisper.cpp`. Swift code does `import whisper` (lowercase — that's the module name baked into the upstream xcframework's modulemap). Our app target is `Spokium`, so no collision. Models downloaded at runtime, not bundled.
- **Global hotkey:** [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) SPM package (v2.4.0+). Wraps Carbon `RegisterEventHotKey` and gives us a SwiftUI recorder view for the settings screen. Default: ⌥Space. Supports toggle mode (default) or push-to-record (`onKeyDown` starts, `onKeyUp` stops) via `pushToRecord` UserDefaults flag.
- **Audio capture:** `AVAudioEngine` with input node tap, writing native-rate CAF to temp directory. Supports user-selectable input device via CoreAudio `AudioUnitSetProperty` (stored as device UID in UserDefaults). Resampled to 16 kHz mono Float32 by `AudioLoader` before transcription.
- **Paste mechanism:** write to `NSPasteboard.general`, synthesize ⌘V via `CGEvent` (key code 9), optionally restore previous pasteboard contents after 150ms delay. Both auto-paste and clipboard restore are user-configurable.
- **Concurrency:** `actor` for `Transcriber` (whisper context isolation), `@Observable` for UI state (`RecordingController`, `ModelManager`). No Combine — uses Swift async/await throughout.

## Hard constraints

- **No network calls** for transcription or telemetry. Model downloads from Hugging Face are the only allowed network use.
- **No transcription history on disk.** The pasted text must not be persisted. Logs must not include transcribed content — log only metadata (language, character count). An opt-in `TranscriptHistory` keeps the last 5 transcripts in memory only when `AppDefaults.keepRecentTranscripts` is true (default false); the store is cleared on `RecordingController.cleanup()` and via the "Clear History" menu item, and never serialised.
- **No dock icon ever.** `LSUIElement = true` is set through generated Info.plist build settings. Settings windows are brought to front via `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront`; do not switch the app to `.regular`.
- **Restore the pasteboard** after pasting so we don't clobber whatever the user had copied (when enabled in settings).

## Entitlements

The app is sandboxed. Entitlements are generated from the Xcode target's Signing & Capabilities build settings; there is currently no checked-in `.entitlements` file. The following entitlements are set on the target:

| Entitlement | Required for |
|---|---|
| `com.apple.security.app-sandbox` | The sandbox itself. |
| `com.apple.security.device.audio-input` | Microphone capture via `AVAudioEngine`. |
| `com.apple.security.network.client` | Outbound HTTPS to Hugging Face for model downloads. |

Things that do **not** need an entitlement:
- `CGEventPost` for the synthesized ⌘V keystroke — gated by the user-granted Accessibility permission, not by sandbox.
- Carbon `RegisterEventHotKey` — works inside the sandbox.

## Locked design decisions

- **Hotkey** — toggle style. Tap to start recording, tap again to stop and transcribe.
- **Paragraph splitting** — RMS-based silence detection on the recorded audio samples (50ms windows, configurable threshold). Silence gaps above the threshold insert paragraph breaks between whisper segments.
- **Custom dictionary** — bias via whisper's `initial_prompt`. User-entered names/spellings are joined into the prompt before each transcription. Token count is shown live using `whisper_token_count` against the loaded model.
- **Snippets** — post-transcription find/replace. JSON-encoded `[Snippet]` (id, trigger, replacement) stored in UserDefaults. Applied after whisper output, before paste. Case-insensitive, whole-word regex match (`\b…\b`).
- **Model storage** — no bundled model. Models live at `~/Library/Application Support/Spokium/models/` (resolved via `FileManager` APIs). Models are downloaded from Hugging Face (`ggerganov/whisper.cpp` repo, `ggml-*.bin` files) and validated with GGML magic bytes and SHA-1 checksums before acceptance. Settings → Model tab shows a list with sizes + quality notes. A "Show in Finder" button lets users manage models manually.
- **Model validation** — downloads are checked for HTTP 2xx status, GGML format magic bytes (ggml/ggmf/ggjt), and SHA-1 checksum match against known hashes.
- **Distribution** — GitHub Releases, signed with Developer ID and notarized via Apple. Hardened Runtime enabled.

## Repo layout

The Xcode project lives in a `Spokium/` subdirectory at the repo root.

```
spokium-macos/
├── README.md
├── AGENTS.md
├── .gitignore
└── Spokium/
    ├── Spokium.xcodeproj/
    ├── Frameworks/
    │   └── whisper.xcframework     # tracked in this checkout, rebuildable from whisper.cpp
    └── Spokium/
        ├── App/                    # SpokiumApp entry point
        ├── MenuBar/                # AppDelegate (+ Menu/Submenus/StatusItem/Errors extensions),
        │                           #   MenuBarIcon
        ├── Recording/              # RecordingController (+ Segments/Transcription
        │                           #   extensions), RecordingMonitors (level/auto-stop/split/Esc
        │                           #   timers), TranscriptionQueue (serial chain + whisper run),
        │                           #   RecordingTypes (state + error enums), RecordingOverlay (HUD)
        ├── Audio/                  # AudioRecorder (AVAudioEngine capture),
        │                           #   AudioDevices (CoreAudio input device enumeration),
        │                           #   RecordingSounds
        ├── Transcription/          # Transcriber (whisper.cpp actor), AudioLoader (resampling),
        │                           #   ModelLocator (directory management + migration),
        │                           #   SilenceDetector + DictionaryPromptBuilder (pure helpers)
        ├── Hotkey/                 # HotkeyName (KeyboardShortcuts.Name extension)
        ├── Paste/                  # Paster (pasteboard + CGEvent ⌘V simulation)
        ├── Settings/               # ModelManager (download/validate/select models),
        │   │                       #   ModelPerformanceStore, SettingsView (TabView root),
        │   │                       #   Snippets (find/replace post-processing)
        │   └── Tabs/               # GeneralTab, TranscriptionTab, ModelTab, DictionaryTab,
        │                           #   SnippetsTab
        └── Assets.xcassets
```

`RecordingController` and `AppDelegate` are split across multiple files using same-type extensions in the `Recording/` and `MenuBar/` folders. Shared stored properties on these classes are declared at default (internal) visibility so the extensions can mutate them. External callers don't mutate this state in practice; if that ever changes, the simplest fix is to put state mutation behind methods on the main class.

## Key implementation details

### State machine (RecordingController)
`idle` → `starting` → `recording` → `finishing` → `idle`. `starting` prevents double-start races while microphone/audio setup is in flight. The `finishing` state covers transcription + paste. Errors are surfaced via `lastError: RecordingError?` which AppDelegate observes and displays as `NSAlert`. Error cases: `.noModel`, `.microphoneDenied`, `.recordingFailed`, `.transcriptionFailed`, `.downloadFailed`, `.noAccessibility`. Transcription task is tracked and cancelled on quit, but quit cleanup still needs a direct `transcriber?.abort()` call and active-recorder stop/delete handling. User can cancel at any state via Esc (global `NSEvent.addGlobalMonitorForEvents` while recording or transcribing) or via the menu item.

### Cancel during transcription
`Transcriber` exposes a nonisolated `abort()` method that flips an `Atomic<Bool>` inside a small `Sendable` wrapper. The flag's pointer is passed to whisper via `params.abort_callback_user_data`; the C callback reads the bool. Whisper polls this between graph computations and exits early, so cancellation actually halts inference instead of just discarding the result. `Transcriber.transcribe(...)` throws `TranscriberError.cancelled` when the flag was set, which `RecordingController` catches silently.

### Auto-stop after time limit
`RecordingController.startAutoStopTask()` schedules a `Task` that sleeps for `maxRecordingMinutes` (UserDefaults, default 10 min, 0 = no limit) then calls `stop()`. Cancelled when the user manually stops, cancels, or push-to-record releases.

### Audio level meter
`AudioRecorder` computes per-buffer RMS in the tap closure and writes it to a small `Sendable` `AudioLevelMeter` backed by `Synchronization.Atomic`. `RecordingController` polls it on a 50 ms `Timer` during recording, exposing a smoothed `inputLevel: Float` (`@Observable`). `RecordingOverlay` displays this as a SwiftUI mic icon whose red fill is masked from the bottom up based on the normalized level.

### Transcriber (actor)
Wraps whisper.cpp C API. Lazy-loads model context with GPU enabled (falls back to CPU if GPU init fails). Caches context across transcriptions (unloaded on app quit via `applicationShouldTerminate` → `.terminateLater` pattern). Whisper logs are suppressed via `whisper_log_set` no-op callback. Also exposes `tokenCount(for:)` for dictionary token budget display.

### Audio input device selection
Menu bar dropdown includes an "Input Device" submenu listing available physical devices via CoreAudio (`AudioObjectGetPropertyData`). Aggregate and hidden devices are filtered out. Selected device UID is stored in UserDefaults; applied via `AudioUnitSetProperty` on the engine's input node before recording starts. "System Default" shows the current default device name. Settings → General has the same picker (they share the same UserDefaults key).

### Model selection in menu bar
Dropdown also includes a "Model" submenu listing downloaded models with the current selection checkmarked, plus a "Manage Models…" item that opens Settings. Updating the selection writes to the same `selectedModel` UserDefaults key the Settings UI uses.

### Snippets pipeline
After `Transcriber.transcribe(...)` returns text, `RecordingController.transcribe` runs `SnippetStore.apply(to:)` before sending to `Paster`. Each snippet's trigger is escaped (`NSRegularExpression.escapedPattern`) and wrapped in `\b…\b` boundaries; matches are replaced with the user's replacement string (also escaped via `escapedTemplate`).

### Model downloads
Uses `URLSessionDownloadTask` with KVO on `progress.fractionCompleted`. The actual download task is stored so cancellation works (not just the wrapping Swift Task). After download: validates HTTP status, checks GGML magic bytes, computes streaming SHA-1 (1MB chunks via CommonCrypto), then moves to final location atomically.

### Silence detection
Operates on the 16kHz Float32 samples in 50ms windows. Computes RMS energy per window. Consecutive windows below threshold (0.01) are grouped; if the group spans ≥ the configured silence duration, a break point is recorded at the midpoint. These break points are matched to whisper segment boundaries (±0.5s tolerance) to insert paragraph breaks.

### Overlay HUD
`NSPanel` with `.borderless` + `.nonactivatingPanel` style, `.floating` level, `ignoresMouseEvents`. Positioned at 1/3 from bottom of screen. Recording state shows the level-driven mic icon (see above) plus a "Recording" label. Transcribing state shows a `ProgressView` spinner with "Transcribing…".

### Settings window lifecycle
Opens via `NSHostingSceneRepresentation.environment.openSettings()`. `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront` brings the window to front while `LSUIElement` keeps the app out of the Dock.

### Current architecture gaps to preserve in recommendations
- `AudioLoader.loadResampled(url:)` reads the entire recording into memory.
- The app cannot start a second recording while `finishing`; solving that needs a transcription queue.
- The app cannot change input devices mid-recording; solving that safely needs segmented recordings.

### Tests
- Test target: `SpokiumTests` (Swift Testing, not XCTest). Run via `RunAllTests` or `⌘U`.
- Tests live under `Spokium/SpokiumTests/` and `@testable import Spokium` for internal access.
- Coverage spans pure logic and the audio pipeline up to (but not including) whisper inference:
  - `SnippetStore.apply(_:to:)` — including Unicode triggers, embedded punctuation, and triggers with leading/trailing non-word characters (C++, Mr., #hello).
  - `SilenceDetector.breaks(...)` — patterns, exact-threshold boundaries, odd sample rates, zero-rate guard, silence at buffer start.
  - `DictionaryPromptBuilder.prompt(from:)` — entry parsing.
  - `WhisperModel.validateFile(at:expectedSHA1:)` — magic + SHA-1 checks.
  - `WhisperModel.all` metadata sanity — SHA-1 format, file naming convention, HuggingFace URLs.
  - `ModelPerformanceStore.merge` / `Record.formattedSpeed` / `.summary` — aggregation.
  - `AudioLoader.loadResampled(url:)` — sample-count, RMS preservation, stereo downmix, error path. Audio fixtures are generated at test time via `AVAudioFile` (no checked-in binaries).
- Test structs are `@MainActor` because the project's default actor isolation is MainActor — non-isolated tests can't initialize MainActor types like `Snippet`. New test types should follow the same pattern.
- When adding a testable behavior, prefer extracting a pure helper (like `SilenceDetector`) over making tests reach into actor internals. The helper goes next to the production code; the test stays minimal.

## Hidden debug mode

Enable from terminal (no UI surface):

```sh
defaults write com.spokium.mac debugMode -bool true
```

When on:
- Recorded audio is **moved** to `~/Library/Containers/com.spokium.mac/Data/Library/Application Support/Spokium/debug-recordings/` after each transcription instead of being deleted. Folder is size-capped at 100 MB (oldest files dropped first).
- A markdown sidecar (`{audio-basename}.md`) is written next to each audio file containing per-segment whisper output: index, start/end timestamps (s), `no_speech_prob`, raw text. `Transcriber` populates `TranscriptionResult.debugSegments` only when `AppDefaults.debugMode` is true; `TranscriptionQueue` captures it and `DebugRecordingStore.persistAndConsume(_:debugSegments:)` writes the sidecar.
- A "Reveal Debug Folder" item appears at the bottom of the menu bar dropdown.

**No transcript text is written to OSLog** — debug data is confined to the sidecar files in the debug folder so cleanup is a single `rm -rf` of the folder.

Disable:

```sh
defaults write com.spokium.mac debugMode -bool false
```

On disable, the debug folder is wiped (via `UserDefaults.didChangeNotification` observer + a launch-time idempotent cleanup). The menu item disappears on next menu open.

This is a developer affordance for diagnosing whisper hallucinations and false-positive "no speech detected" cases. Privacy posture: opt-in via terminal, sandbox-only, never network, cleared on disable.

## Conventions

- Keep files small and feature-scoped — one concept per file.
- Prefer `actor` / `async` over GCD for concurrency.
- No third-party deps beyond `whisper.cpp` and `KeyboardShortcuts` without discussion.
- No comments restating what the code does. Comments are reserved for non-obvious *why*.

## Things that will trip you up

- **Accessibility permission** is required to send ⌘V. The app shows an alert if paste fails (not prompted at launch). This is independent of sandbox.
- **Microphone permission** is requested on first recording via `AVCaptureDevice.requestAccess`.
- **Pasteboard restore timing** — restoring too quickly means the ⌘V pastes the *old* contents. 150ms delay after keystroke. Change count is captured right after write (not after the sleep) to avoid clobbering clipboard changes from other apps.
- **Whisper sample rate** — whisper.cpp requires 16 kHz mono Float32. `AudioLoader` resamples from the device's native format.
- **Menu bar app lifecycle** — `LSUIElement` apps need explicit window management. Settings uses `NSHostingSceneRepresentation` + `NSApp.activate(ignoringOtherApps: true)` and must not switch to `.regular` activation policy.
- **Sandbox container paths** — every path must resolve through `FileManager` APIs, never hard-coded.
- **Swift 6 strict concurrency** — whisper C pointers need careful isolation, `nonisolated(unsafe)` wrappers, or atomic `Sendable` state. AVFAudio imports need `@preconcurrency`. Audio tap closures must not capture `@MainActor`-isolated `self`; use standalone flag/meter objects instead.
- **Clean shutdown** — whisper Metal residency sets must be freed before C++ global destructors run. `applicationShouldTerminate` with `.terminateLater` calls `RecordingController.cleanup()`, which unloads the transcriber. Direct whisper abort on quit is still a known gap.
- **Model directory migration** — old paths were `spokium-macos/models`, `whisper-macos/models`, and `vox-macos/models`; now `Spokium/models`. `ModelLocator.migrateFromOldDirectory()` runs on launch.

## Settings layer (`Spokium/Settings/AppDefaults.swift`)

All persisted settings flow through `AppDefaults` (typed accessors) and `DefaultsKey` (key string constants). Production code uses `AppDefaults.foo` for reads/writes; SwiftUI views use `@AppStorage(DefaultsKey.foo)` with inline `AppDefaults.fooDefault` constants for the fallback. Direct `UserDefaults.standard` usage is limited to `Snippets` and `ModelPerformanceStore`, which own their own JSON-encoded blobs and reference `DefaultsKey.snippets` / `DefaultsKey.modelPerformance` respectively.

When adding a new setting:
1. Add the key constant to `DefaultsKey` and the default value constant to `AppDefaults`.
2. Add a get/set computed property on `AppDefaults`.
3. Use `@AppStorage(DefaultsKey.x) private var ... = AppDefaults.xDefault` in the SwiftUI tab.
4. Update the table below.

The layer is `nonisolated` so it's callable from any actor context. `UserDefaults` is thread-safe.

## UserDefaults keys

| Key | Type | Default | Used in |
|---|---|---|---|
| `selectedLanguage` | String | `"auto"` | TranscriptionTab, RecordingController |
| `paragraphSplitting` | Bool | `true` | TranscriptionTab, RecordingController |
| `silenceThreshold` | Double | `3.0` | TranscriptionTab, RecordingController |
| `autoPaste` | Bool | `true` | TranscriptionTab, Paster |
| `preserveClipboard` | Bool | `true` | TranscriptionTab, Paster |
| `dictionaryEntries` | String | `""` | DictionaryTab, RecordingController |
| `selectedModel` | String | (auto) | ModelManager |
| `selectedInputDevice` | String | `""` | AppDelegate menu, AudioRecorder, GeneralTab |
| `pushToRecord` | Bool | `false` | GeneralTab, RecordingController |
| `playSounds` | Bool | `false` | GeneralTab, RecordingSounds |
| `snippets` | Data | `[]` (JSON) | SnippetsTab, SnippetStore (applied in RecordingController) |
| `maxRecordingMinutes` | Double | `10` | TranscriptionTab, RecordingController auto-stop (0 = no limit) |

## Out of scope (do not build)

- Any kind of cloud sync, account, or telemetry.
- LLM-based rewriting of the transcript.
- Live streaming captions.
- Transcription history UI.
