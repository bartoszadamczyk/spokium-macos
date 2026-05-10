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
- **Whisper integration:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) via a locally-built XCFramework. The user clones `whisper.cpp` next to this repo, runs `./build-xcframework.sh`, and copies the resulting `whisper.xcframework` into `Vox/Frameworks/`. The framework is gitignored. Swift code does `import whisper` (lowercase — that's the module name baked into the upstream xcframework's modulemap). Our app target is `Vox`, so no collision. Models downloaded at runtime, not bundled.
- **Global hotkey:** [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) SPM package (v2.4.0+). Wraps Carbon `RegisterEventHotKey` and gives us a SwiftUI recorder view for the settings screen. Default: ⌥Space.
- **Audio capture:** `AVAudioEngine` with input node tap, writing native-rate CAF to temp directory. Resampled to 16 kHz mono Float32 by `AudioLoader` before transcription.
- **Paste mechanism:** write to `NSPasteboard.general`, synthesize ⌘V via `CGEvent` (key code 9), optionally restore previous pasteboard contents after 150ms delay. Both auto-paste and clipboard restore are user-configurable.
- **Concurrency:** `actor` for `Transcriber` (whisper context isolation), `@Observable` for UI state (`RecordingController`, `ModelManager`). No Combine — uses Swift async/await throughout.

## Hard constraints

- **No network calls** for transcription or telemetry. Model downloads from Hugging Face are the only allowed network use.
- **No transcription history on disk.** The pasted text must not be persisted. Logs must not include transcribed content — log only metadata (language, character count).
- **No dock icon.** `LSUIElement = true` in `Info.plist`. The app is menu-bar only (switches to `.regular` activation policy temporarily when settings window is open).
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
- **Custom dictionary** — bias via whisper's `initial_prompt` only. User-entered names/spellings are joined into the prompt before each transcription. No post-processing find/replace in v1.
- **Model storage** — no bundled model. Models live at `~/Library/Application Support/vox-macos/models/` (resolved via `FileManager` APIs). Models are downloaded from Hugging Face (`ggerganov/whisper.cpp` repo, `ggml-*.bin` files) and validated with GGML magic bytes and SHA-1 checksums before acceptance. Settings → Model tab shows a list with sizes + quality notes. A "Show in Finder" button lets users manage models manually.
- **Model validation** — downloads are checked for HTTP 2xx status, GGML format magic bytes (ggml/ggmf/ggjt), and SHA-1 checksum match against known hashes.
- **Distribution** — GitHub Releases, unsigned by default.

## Repo layout

The Xcode project lives in a `Vox/` subdirectory at the repo root.

```
vox-macos/
├── README.md
├── AGENTS.md
├── .gitignore
└── Vox/
    ├── Vox.xcodeproj/
    ├── Frameworks/
    │   └── whisper.xcframework     # gitignored, built from source
    └── Vox/
        ├── App/                    # VoxApp entry point, AppDelegate, RecordingController,
        │                           #   RecordingOverlay, MenuBarIcon
        ├── Audio/                  # AudioRecorder (AVAudioEngine capture)
        ├── Transcription/          # Transcriber (whisper.cpp actor), AudioLoader (resampling),
        │                           #   ModelLocator (directory management + migration)
        ├── Hotkey/                 # HotkeyName (KeyboardShortcuts.Name extension)
        ├── Paste/                  # Paster (pasteboard + CGEvent ⌘V simulation)
        ├── Settings/               # ModelManager (download/validate/select models),
        │                           #   SettingsView (General, Model, Dictionary tabs)
        └── Assets.xcassets
```

## Key implementation details

### State machine (RecordingController)
`idle` → `recording` → `finishing` → `idle`. The `finishing` state covers transcription + paste. Errors are surfaced via `lastError: RecordingError?` which AppDelegate observes and displays as `NSAlert`.

### Transcriber (actor)
Wraps whisper.cpp C API. Lazy-loads model context with GPU enabled. Caches context across transcriptions (unloaded on app quit via `applicationShouldTerminate` → `.terminateLater` pattern). Whisper logs are suppressed via `whisper_log_set` no-op callback.

### Model downloads
Uses `URLSessionDownloadTask` with KVO on `progress.fractionCompleted`. The actual download task is stored so cancellation works (not just the wrapping Swift Task). After download: validates HTTP status, checks GGML magic bytes, computes streaming SHA-1 (1MB chunks via CommonCrypto), then moves to final location atomically.

### Silence detection
Operates on the 16kHz Float32 samples in 50ms windows. Computes RMS energy per window. Consecutive windows below threshold (0.01) are grouped; if the group spans ≥ the configured silence duration, a break point is recorded at the midpoint. These break points are matched to whisper segment boundaries (±0.5s tolerance) to insert paragraph breaks.

### Overlay HUD
`NSPanel` with `.borderless` + `.nonactivatingPanel` style, `.floating` level, `ignoresMouseEvents`. Positioned at 1/3 from bottom of screen. Shows "Recording" (red mic icon) or "Transcribing…" (spinner) depending on state.

### Settings window lifecycle
Opens via `NSHostingSceneRepresentation.environment.openSettings()`. Switches app activation policy to `.regular` so the window comes to front reliably, then back to `.accessory` when all windows close (observed via `NSWindow.willCloseNotification`).

## Conventions

- Keep files small and feature-scoped — one concept per file.
- Prefer `actor` / `async` over GCD for concurrency.
- No third-party deps beyond `whisper.cpp` and `KeyboardShortcuts` without discussion.
- No comments restating what the code does. Comments are reserved for non-obvious *why*.

## Things that will trip you up

- **Accessibility permission** is required to send ⌘V. The app prompts at launch and shows an alert if paste fails. This is independent of sandbox.
- **Microphone permission** is requested on first recording via `AVCaptureDevice.requestAccess`.
- **Pasteboard restore timing** — restoring too quickly means the ⌘V pastes the *old* contents. 150ms delay after keystroke. Change count is captured right after write (not after the sleep) to avoid clobbering clipboard changes from other apps.
- **Whisper sample rate** — whisper.cpp requires 16 kHz mono Float32. `AudioLoader` resamples from the device's native format.
- **Menu bar app lifecycle** — `LSUIElement` apps need explicit window management. Settings uses `NSHostingSceneRepresentation` + activation policy switching.
- **Sandbox container paths** — every path must resolve through `FileManager` APIs, never hard-coded.
- **Swift 6 strict concurrency** — whisper C pointers need `nonisolated(unsafe)` and `@unchecked Sendable` wrappers. AVFAudio imports need `@preconcurrency`.
- **Clean shutdown** — whisper Metal residency sets must be freed before C++ global destructors run. `applicationShouldTerminate` with `.terminateLater` calls `Transcriber.unload()` first.
- **Model directory migration** — old path was `whisper-macos/models`, now `vox-macos/models`. `ModelLocator.migrateFromOldDirectory()` runs on launch.

## UserDefaults keys

| Key | Type | Default | Used in |
|---|---|---|---|
| `selectedLanguage` | String | `"auto"` | GeneralTab, RecordingController |
| `paragraphSplitting` | Bool | `true` | GeneralTab, RecordingController |
| `silenceThreshold` | Double | `1.5` | GeneralTab, RecordingController |
| `autoPaste` | Bool | `true` | GeneralTab, Paster |
| `preserveClipboard` | Bool | `true` | GeneralTab, Paster |
| `dictionaryEntries` | String | `""` | DictionaryTab, RecordingController |
| `selectedModel` | String | (auto) | ModelManager |

## Out of scope (do not build)

- Any kind of cloud sync, account, or telemetry.
- LLM-based rewriting of the transcript.
- Live streaming captions.
- Transcription history UI.
