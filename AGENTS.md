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
- **Whisper integration:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) via a locally-built XCFramework. The user clones `whisper.cpp` next to this repo, runs `./build-xcframework.sh`, and copies the resulting `whisper.xcframework` into `Spokium/Frameworks/`. The framework is gitignored. Swift code does `import whisper` (lowercase — that's the module name baked into the upstream xcframework's modulemap). Our app target is `Spokium`, so no collision. Models downloaded at runtime, not bundled.
- **Global hotkey:** [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) SPM package (v2.4.0+). Wraps Carbon `RegisterEventHotKey` and gives us a SwiftUI recorder view for the settings screen. Default: ⌥Space. Supports toggle mode (default) or push-to-record (`onKeyDown` starts, `onKeyUp` stops) via `pushToRecord` UserDefaults flag.
- **Audio capture:** `AVAudioEngine` with input node tap, writing native-rate CAF to temp directory. Supports user-selectable input device via CoreAudio `AudioUnitSetProperty` (stored as device UID in UserDefaults). Resampled to 16 kHz mono Float32 by `AudioLoader` before transcription.
- **Paste mechanism:** write to `NSPasteboard.general`, synthesize ⌘V via `CGEvent` (key code 9), optionally restore previous pasteboard contents after 150ms delay. Both auto-paste and clipboard restore are user-configurable.
- **Concurrency:** `actor` for `Transcriber` (whisper context isolation), `@Observable` for UI state (`RecordingController`, `ModelManager`). No Combine — uses Swift async/await throughout.

## Hard constraints

- **No network calls** for transcription or telemetry. Model downloads from Hugging Face are the only allowed network use.
- **No transcription history on disk.** The pasted text must not be persisted. Logs must not include transcribed content — log only metadata (language, character count).
- **No dock icon ever.** `LSUIElement = true` in `Info.plist`. The app stays in `.accessory` activation policy permanently — Settings windows are brought to front via `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront` without switching to `.regular`.
- **Restore the pasteboard** after pasting so we don't clobber whatever the user had copied (when enabled in settings).

## Entitlements

The app is sandboxed. The following entitlements are set on the target:

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
    │   └── whisper.xcframework     # gitignored, built from source
    └── Spokium/
        ├── App/                    # SpokiumApp entry point, AppDelegate, RecordingController,
        │                           #   RecordingOverlay, MenuBarIcon
        ├── Audio/                  # AudioRecorder (AVAudioEngine capture),
        │                           #   AudioDevices (CoreAudio input device enumeration)
        ├── Transcription/          # Transcriber (whisper.cpp actor), AudioLoader (resampling),
        │                           #   ModelLocator (directory management + migration)
        ├── Hotkey/                 # HotkeyName (KeyboardShortcuts.Name extension)
        ├── Paste/                  # Paster (pasteboard + CGEvent ⌘V simulation)
        ├── Settings/               # ModelManager (download/validate/select models),
        │                           #   SettingsView (General, Transcription, Model, Dictionary, Snippets tabs),
        │                           #   Snippets (find/replace post-processing)
        └── Assets.xcassets
```

## Key implementation details

### State machine (RecordingController)
`idle` → `recording` → `finishing` → `idle`. The `finishing` state covers transcription + paste. Errors are surfaced via `lastError: RecordingError?` which AppDelegate observes and displays as `NSAlert`. Error cases: `.noModel`, `.microphoneDenied`, `.recordingFailed`, `.transcriptionFailed`, `.downloadFailed`, `.noAccessibility`. Transcription task is tracked and cancelled on quit. User can cancel at any state via Esc (global `NSEvent.addGlobalMonitorForEvents` while recording or transcribing) or via the menu item.

### Cancel during transcription
`Transcriber` exposes a nonisolated `abort()` method that flips a `nonisolated(unsafe) Bool` flag inside an `@unchecked Sendable` wrapper. The flag's pointer is passed to whisper via `params.abort_callback_user_data` with a `@convention(c)` callback that reads the bool. Whisper polls this between graph computations and exits early, so cancellation actually halts inference instead of just discarding the result. `Transcriber.transcribe(...)` throws `TranscriberError.cancelled` when the flag was set, which `RecordingController` catches silently.

### Auto-stop after time limit
`RecordingController.startAutoStopTask()` schedules a `Task` that sleeps for `maxRecordingMinutes` (UserDefaults, default 10 min, 0 = no limit) then calls `stop()`. Cancelled when the user manually stops, cancels, or push-to-record releases.

### Audio level meter
`AudioRecorder` computes per-buffer RMS in the tap closure and writes it to a `@unchecked Sendable` `AudioLevelMeter` wrapper (similar pattern to `WriteErrorFlag`). `RecordingController` polls it on a 50 ms `Timer` during recording, exposing a smoothed `inputLevel: Float` (`@Observable`). `RecordingOverlay` displays this as a SwiftUI mic icon whose red fill is masked from the bottom up based on the normalized level (scaled 8x since speech RMS sits around 0.02–0.10).

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
Opens via `NSHostingSceneRepresentation.environment.openSettings()`. The app never leaves `.accessory` policy; `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront` is enough to bring the window to front. No dock icon ever appears.

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
- **Menu bar app lifecycle** — `LSUIElement` apps need explicit window management. Settings uses `NSHostingSceneRepresentation` + `NSApp.activate(ignoringOtherApps: true)` while staying in `.accessory` policy (so no dock icon flashes).
- **Sandbox container paths** — every path must resolve through `FileManager` APIs, never hard-coded.
- **Swift 6 strict concurrency** — whisper C pointers need `nonisolated(unsafe)` and `@unchecked Sendable` wrappers. AVFAudio imports need `@preconcurrency`. Audio tap closures must not capture `@MainActor`-isolated `self` (use standalone `@unchecked Sendable` flag objects instead).
- **Clean shutdown** — whisper Metal residency sets must be freed before C++ global destructors run. `applicationShouldTerminate` with `.terminateLater` calls `Transcriber.unload()` first.
- **Model directory migration** — old paths were `whisper-macos/models` and `vox-macos/models`, now `Spokium/models`. `ModelLocator.migrateFromOldDirectory()` runs on launch.

## UserDefaults keys

| Key | Type | Default | Used in |
|---|---|---|---|
| `selectedLanguage` | String | `"auto"` | TranscriptionTab, RecordingController |
| `paragraphSplitting` | Bool | `true` | TranscriptionTab, RecordingController |
| `silenceThreshold` | Double | `1.5` | TranscriptionTab, RecordingController |
| `autoPaste` | Bool | `true` | TranscriptionTab, Paster |
| `preserveClipboard` | Bool | `true` | TranscriptionTab, Paster |
| `dictionaryEntries` | String | `""` | DictionaryTab, RecordingController |
| `selectedModel` | String | (auto) | ModelManager |
| `selectedInputDevice` | String | `""` | AppDelegate menu, AudioRecorder, GeneralTab |
| `pushToRecord` | Bool | `false` | GeneralTab, RecordingController |
| `snippets` | Data | `[]` (JSON) | SnippetsTab, SnippetStore (applied in RecordingController) |
| `maxRecordingMinutes` | Double | `10` | TranscriptionTab, RecordingController auto-stop (0 = no limit) |

## Out of scope (do not build)

- Any kind of cloud sync, account, or telemetry.
- LLM-based rewriting of the transcript.
- Live streaming captions.
- Transcription history UI.
