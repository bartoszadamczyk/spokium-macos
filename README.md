# spokium-macos

A small, native macOS dictation helper. Tap a global keyboard shortcut to start recording, tap again to stop — the transcribed text is pasted into whatever window is focused. Powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp) running fully on-device.

## Goals

- **Native, lightweight.** Single Swift app, no Electron, no background daemon zoo.
- **Lives in the menu bar.** No dock icon (ever, including when Settings is open). The status item shows idle / recording / transcribing state with a pulsing red waveform icon while recording.
- **Global hotkey to record.** Toggle style (default ⌥Space): tap to start recording, tap again to stop, transcribe, and paste. Push-to-record mode also available (hold while speaking, release to transcribe).
- **On-device only.** All audio and transcription stays local; no network calls except model downloads.
- **Menu bar dropdown** with quick switching for input device and active whisper model (no need to open Settings for routine changes).
- **Snippets.** Define spoken triggers like "calendar link" that get replaced with arbitrary text on paste. Case-insensitive, whole-word matching.
- **Live audio level meter.** Recording overlay shows a microphone icon that fills red from the bottom up based on input volume — instant feedback that the mic is working.
- **Cancel anytime.** Press Esc (or menu item) to discard a recording or abort an in-flight transcription. Whisper's abort callback is wired up, so cancelling during inference actually stops compute.
- **Auto-stop after time limit.** Configurable maximum recording duration (default 10 min) prevents accidentally leaving the hotkey on forever.
- **Settings window** for: language (auto-detect or 99+ languages), model size (tiny / base / small / medium / large-v3 / large-v3-turbo), hotkey (toggle or push-to-record), input device, launch at login, sound effects, auto-stop after N minutes, paragraph splitting, auto-paste, clipboard restore, custom dictionary with token counting, and snippets.
- **Paragraph splitting.** Detects silence gaps in the audio (configurable threshold, default 1.5s) and inserts paragraph breaks so pasted output keeps structure.
- **Pastes into the active window.** Uses the system pasteboard + a synthesized ⌘V. Optionally restores previous clipboard contents after paste. Can also be set to clipboard-only mode (no auto-paste).
- **Paste feedback overlay.** After transcription the HUD briefly confirms the outcome — "Pasted" when auto-paste fires, "Copied to clipboard" when auto-paste is off, and "No speech detected" (with a soft chime) when the transcript came back empty. No transcript content is stored.
- **Accessibility preflight.** Settings → Transcription shows live paste readiness (granted / required) with a "Request Permission" button. The paste pipeline also preflights `AXIsProcessTrusted` before synthesizing ⌘V — without permission the transcript is left on the clipboard instead of dropping silently.
- **Persistent error row in the menu.** The status menu keeps a non-sensitive error message until the user dismisses it. For paste-permission failures it also surfaces "Open Accessibility Settings…" and a one-shot "Turn Off Auto-paste" remediation, so users can recover without digging through Settings.
- **No transcription history.** Nothing is saved to disk after the paste. Logs do not include transcribed content.

## Non-goals

- Streaming / live captioning.
- Cloud transcription.
- A general voice-assistant UX (no commands, no LLM post-processing in v1).
- Multi-user sync, accounts, telemetry.

## High-level architecture

```
┌─────────────────────────────────────────────────────────────┐
│ App (SwiftUI + AppKit)                                      │
│                                                             │
│  NSStatusItem ──► menu bar icon (pulse animation), menu     │
│  Settings scene ──► language, model, hotkey, dictionary     │
│                                                             │
│  ModelManager ──► download / validate / select whisper      │
│        │           models (SHA-1 + GGML magic validation)   │
│        ▼                                                    │
│  KeyboardShortcuts ──► global toggle shortcut (⌥Space)      │
│        │                                                    │
│        ▼                                                    │
│  AudioRecorder (AVAudioEngine) ──► native-rate CAF file     │
│        │                                                    │
│        ▼                                                    │
│  AudioLoader ──► resample to 16kHz mono Float32             │
│        │                                                    │
│        ▼                                                    │
│  Transcriber (whisper.cpp actor) ──► text + language         │
│        │                                                    │
│        ├──► silence detection (RMS energy) ──► paragraphs   │
│        ├──► dictionary biasing (initial_prompt)             │
│        ▼                                                    │
│  Paster (NSPasteboard + CGEvent ⌘V) ──► active window       │
└─────────────────────────────────────────────────────────────┘
```

## Sandbox & permissions

The app runs under App Sandbox. Entitlements are generated from the Xcode target's Signing & Capabilities build settings, not from a checked-in `.entitlements` file. Required entitlements:

- `com.apple.security.app-sandbox`
- `com.apple.security.device.audio-input` — microphone
- `com.apple.security.network.client` — model downloads from Hugging Face

User-granted permissions (prompted at first use, not at install):

- **Microphone** — backed by `NSMicrophoneUsageDescription` in `Info.plist`.
- **Accessibility** — required to synthesize the ⌘V keystroke. User grants this in System Settings → Privacy & Security → Accessibility. Settings → Transcription surfaces a live readiness indicator with a "Request Permission" button so the grant can happen up front; if missing at paste time, the paste is skipped (transcript stays on the clipboard), an alert is shown, the system prompt is triggered, and a persistent menu row offers either "Open Accessibility Settings…", "Turn Off Auto-paste", or "Dismiss".

## Decisions

- **Paragraph splitting** — detects silence from the actual audio samples using RMS energy analysis in 50ms windows. A silence gap above the configurable threshold (default 1.5s) inserts a paragraph break between whisper segments.
- **Custom dictionary** — bias recognition via whisper's `initial_prompt`. The user's custom names/spellings are concatenated into the prompt so the model is more likely to produce them. Dictionary entries are not find/replace rules; snippets handle post-transcription replacement.
- **Model storage** — no bundled model. The app downloads models on demand into the user Application Support directory, under `Spokium/models` as resolved by `FileManager` (inside the sandbox container for sandboxed builds). Settings → Model tab lists available models with size and quality info. Models are downloaded from Hugging Face (`ggerganov/whisper.cpp` repo) and validated with GGML magic bytes and SHA-1 checksums. Models can also be dropped into the folder manually via the "Show in Finder" button.
- **Download validation** — HTTP status code, GGML format magic bytes, and SHA-1 checksum verification before accepting a downloaded model.
- **Output options** — auto-paste (default on) and clipboard restore (default on) are independently configurable. With auto-paste off, text is placed on the clipboard only.
- **Snippets** — post-transcription find/replace. User-defined trigger phrases are matched against the transcript with case-insensitive whole-word matching, replaced before paste.
- **Distribution** — signed with Developer ID and notarized via Apple. Published as `.zip` builds on GitHub Releases.

## Initial Xcode project setup

These settings must be applied to the Spokium target on a fresh checkout (they live in `Spokium.xcodeproj` once set, but a freshly-generated Xcode project will not have them):

| Where | Setting | Value |
|---|---|---|
| General → Minimum Deployments | macOS | **26.3** |
| Signing & Capabilities → App Sandbox | Audio Input | ✓ |
| Signing & Capabilities → App Sandbox | Outgoing Connections (Client) | ✓ |
| Build Settings | `INFOPLIST_KEY_LSUIElement` | **YES** (no dock icon) |
| Build Settings | `INFOPLIST_KEY_NSMicrophoneUsageDescription` | `"Spokium records audio to transcribe your dictation locally."` |
| Build Settings | `Swift Language Version` | **6.0** |
| Build Settings | `Default Actor Isolation` | **MainActor** |
| Signing & Capabilities | Hardened Runtime | ✓ (required for notarization) |

SPM dependency to add (File → Add Package Dependencies):
- `https://github.com/sindresorhus/KeyboardShortcuts` — global hotkey support, attached to the Spokium target

Framework to add: see § *Building from source* below.

## Learning docs

The `docs/` directory is a local learning companion for this app. Start with:

- `docs/README.md` for the learning path.
- `docs/swift-code-tour.md` for a code walkthrough.
- `docs/macos-swift-learning-guide.md` for Swift/macOS concepts mapped to this repo.
- `docs/code-audit-map.md` and `docs/validation-guide.md` for security and behavior checks.

## Building from source

The Xcode project links `Spokium/Frameworks/whisper.xcframework`. In this checkout the framework is present and tracked, but it is still treated as a rebuildable artifact from upstream `whisper.cpp`. If the framework is missing, stale, or you want to verify provenance, rebuild it from source:

1. **Clone whisper.cpp as a sibling of this repo:**
   ```sh
   cd ~/Codeplace          # or wherever this repo lives
   git clone https://github.com/ggml-org/whisper.cpp.git
   ```

2. **Build the XCFramework** (5–15 min on Apple Silicon — builds for arm64 + x86_64 across macOS, iOS, simulators):
   ```sh
   cd whisper.cpp
   ./build-xcframework.sh
   ```

3. **Copy the result into this project:**
   ```sh
   cp -R ~/Codeplace/whisper.cpp/build-apple/whisper.xcframework \
         ~/Codeplace/spokium-macos/Spokium/Frameworks/
   ```
   *(Adjust source path if `build-xcframework.sh` writes the framework elsewhere — `find ~/Codeplace/whisper.cpp -name whisper.xcframework -type d` will tell you.)*

4. **Verify it is attached to the Xcode target** (the project currently references it already; this is only needed if you recreate the project or remove the reference):
   - Drag `Spokium/Frameworks/whisper.xcframework` from Finder onto the **Spokium** project icon in Xcode's project navigator.
   - Uncheck **Copy items if needed**, ensure **Spokium** target is selected, click **Finish**.
   - Target → **General** → **Frameworks, Libraries, and Embedded Content** → set the framework's mode to **Embed & Sign**.

5. **Build & run** (⌘R).

### Updating to a newer whisper.cpp

```sh
cd ~/Codeplace/whisper.cpp
git pull
./build-xcframework.sh
cp -R build-apple/whisper.xcframework ~/Codeplace/spokium-macos/Spokium/Frameworks/
```

Xcode picks up the updated framework on next build.

## Status

All core functionality is implemented and working:

- [x] **Phase 1** — menu-bar shell. `NSStatusItem` with red pulsing waveform icon while recording, Settings scene with five tabs (General, Transcription, Model, Dictionary, Snippets). Menu bar dropdown also exposes input device and model submenus.
- [x] **Phase 2** — hotkey + audio capture. `KeyboardShortcuts` SPM, default ⌥Space, toggle or push-to-record mode, `AVAudioEngine` records native-rate `.caf` to the sandbox's tmp dir. Input device selectable from menu bar and Settings.
- [x] **Phase 3a** — transcription wired. On stop: resample to 16kHz mono → run whisper inference → output text with language detection. Audio file auto-deleted after transcription. Whisper context cached across sessions for fast re-transcription. GPU fallback to CPU if GPU init fails.
- [x] **Phase 3b** — model picker UI. Settings → Model tab lists 6 models (tiny through large-v3-turbo), downloads from Hugging Face with progress bar, validates with SHA-1 checksums and GGML magic bytes. "Show in Finder" button for manual model management.
- [x] **Phase 4** — paste pipeline. Save current pasteboard, write transcript, synthesize ⌘V via `CGEvent`, optionally restore previous pasteboard after 150ms. Configurable auto-paste and clipboard restore settings.
- [x] **Phase 5** — post-processing. Custom dictionary biasing via whisper's `initial_prompt` with real token counting (224 max). Paragraph splitting via RMS-based silence detection on recorded audio (configurable threshold). User-defined snippets find/replace after transcription.
- [x] **Phase 6** — polish. Pulsing menu bar icon during recording, floating overlay HUD with live audio level meter (mic icon fills red bottom-up) and brief pasted / copied / no-speech-detected confirmation, cancel-anytime via Esc or menu (uses whisper's abort callback for true mid-flight interruption), auto-stop after configurable time limit, error alerts plus a persistent error row in the status menu (no model, mic denied, recording failed, transcription failed, download failed, accessibility missing) with a one-shot "Turn Off Auto-paste" remediation for paste failures, Accessibility-permission preflight in Settings and before each ⌘V synth, launch at login, sound effects, transcription timing logs, settings persistence audit, download validation, temp file cleanup, model directory migration. `LSUIElement` stays enabled so no Dock icon appears.
- [x] **Phase 7** — distribution scripts. `scripts/release.sh` archives, exports with `method = developer-id`, submits to Apple notarization, staples the app, writes `dist/<version>/`, and installs to `/Applications`. Hardened Runtime is enabled in the target build settings.

### Settings (UserDefaults keys)

| Key | Type | Default | Description |
|---|---|---|---|
| `selectedLanguage` | String | `"auto"` | Whisper language code or `"auto"` for detection |
| `paragraphSplitting` | Bool | `true` | Insert paragraph breaks on silence gaps |
| `silenceThreshold` | Double | `1.5` | Seconds of silence to trigger a paragraph break |
| `autoPaste` | Bool | `true` | Simulate ⌘V after transcription |
| `preserveClipboard` | Bool | `true` | Restore clipboard after paste |
| `dictionaryEntries` | String | `""` | Newline-separated custom names/spellings |
| `selectedModel` | String | (auto) | Name of the selected whisper model |
| `selectedInputDevice` | String | `""` | Audio input device UID (empty = system default) |
| `pushToRecord` | Bool | `false` | If true, hold shortcut to record instead of toggle |
| `playSounds` | Bool | `false` | Play system sound effects for recording start, paste/copy, and empty result |
| `snippets` | Data (JSON) | `[]` | Array of `{id, trigger, replacement}` for find/replace |
| `maxRecordingMinutes` | Double | `10` | Auto-stop recording after N minutes (0 = no limit) |
