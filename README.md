# vox-macos

A small, native macOS dictation helper. Tap a global keyboard shortcut to start recording, tap again to stop — the transcribed text is pasted into whatever window is focused. Powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp) running fully on-device.

## Goals

- **Native, lightweight.** Single Swift app, no Electron, no background daemon zoo.
- **Lives in the menu bar.** No dock icon. The status item shows idle / recording / transcribing state with a pulsing red pill indicator while recording.
- **Global hotkey to record.** Toggle style (default ⌥Space): tap to start recording, tap again to stop, transcribe, and paste. Push-to-record mode also available (hold while speaking, release to transcribe).
- **On-device only.** All audio and transcription stays local; no network calls except model downloads.
- **Menu bar dropdown** with quick switching for input device and active whisper model (no need to open Settings for routine changes).
- **Snippets.** Define spoken triggers like "calendar link" that get replaced with arbitrary text on paste. Case-insensitive, whole-word matching.
- **Settings window** for: language (auto-detect or 99+ languages), model size (tiny / base / small / medium / large-v3 / large-v3-turbo), hotkey (toggle or push-to-record), input device, launch at login, paragraph splitting, auto-paste, clipboard restore, custom dictionary with token counting, and snippets.
- **Paragraph splitting.** Detects silence gaps in the audio (configurable threshold, default 1.5s) and inserts paragraph breaks so pasted output keeps structure.
- **Pastes into the active window.** Uses the system pasteboard + a synthesized ⌘V. Optionally restores previous clipboard contents after paste. Can also be set to clipboard-only mode (no auto-paste).
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

The app runs under App Sandbox. Required entitlements:

- `com.apple.security.app-sandbox`
- `com.apple.security.device.audio-input` — microphone
- `com.apple.security.network.client` — model downloads from Hugging Face

User-granted permissions (prompted at first use, not at install):

- **Microphone** — backed by `NSMicrophoneUsageDescription` in `Info.plist`.
- **Accessibility** — required to synthesize the ⌘V keystroke. User grants this in System Settings → Privacy & Security → Accessibility. If missing, the app shows an alert after transcription and triggers the system prompt.

## Decisions

- **Paragraph splitting** — detects silence from the actual audio samples using RMS energy analysis in 50ms windows. A silence gap above the configurable threshold (default 1.5s) inserts a paragraph break between whisper segments.
- **Custom dictionary** — bias recognition via whisper's `initial_prompt`. The user's custom names/spellings are concatenated into the prompt so the model is more likely to produce them. (No post-processing find/replace in v1.)
- **Model storage** — no bundled model. The app downloads models on demand into `~/Library/Application Support/vox-macos/models/`. Settings → Model tab lists available models with size and quality info. Models are downloaded from Hugging Face (`ggerganov/whisper.cpp` repo) and validated with GGML magic bytes and SHA-1 checksums. Models can also be dropped into the folder manually via the "Show in Finder" button.
- **Download validation** — HTTP status code, GGML format magic bytes, and SHA-1 checksum verification before accepting a downloaded model.
- **Output options** — auto-paste (default on) and clipboard restore (default on) are independently configurable. With auto-paste off, text is placed on the clipboard only.
- **Snippets** — post-transcription find/replace. User-defined trigger phrases are matched against the transcript with case-insensitive whole-word matching, replaced before paste.
- **Distribution** — signed with Developer ID and notarized via Apple. Published as `.zip` builds on GitHub Releases.

## Initial Xcode project setup

These settings must be applied to the Vox target on a fresh checkout (they live in `Vox.xcodeproj` once set, but a freshly-generated Xcode project will not have them):

| Where | Setting | Value |
|---|---|---|
| General → Minimum Deployments | macOS | **26.3** |
| Signing & Capabilities → App Sandbox | Audio Input | ✓ |
| Signing & Capabilities → App Sandbox | Outgoing Connections (Client) | ✓ |
| Build Settings | `INFOPLIST_KEY_LSUIElement` | **YES** (no dock icon) |
| Build Settings | `INFOPLIST_KEY_NSMicrophoneUsageDescription` | `"Vox records audio to transcribe your dictation locally."` |
| Build Settings | `Swift Language Version` | **6.0** |
| Build Settings | `Default Actor Isolation` | **MainActor** |
| Signing & Capabilities | Hardened Runtime | ✓ (required for notarization) |

SPM dependency to add (File → Add Package Dependencies):
- `https://github.com/sindresorhus/KeyboardShortcuts` — global hotkey support, attached to the Vox target

Framework to add: see § *Building from source* below.

## Building from source

The Xcode project depends on a `whisper.xcframework` that is **not committed** to this repo (~50–100 MB binary, gitignored). You build it yourself from the upstream `whisper.cpp` repo. One-time setup:

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
         ~/Codeplace/vox-macos/Vox/Frameworks/
   ```
   *(Adjust source path if `build-xcframework.sh` writes the framework elsewhere — `find ~/Codeplace/whisper.cpp -name whisper.xcframework -type d` will tell you.)*

4. **Add it to the Xcode target** (only needed on the first setup — once the project file references it, this step is skipped on future rebuilds):
   - Drag `Vox/Frameworks/whisper.xcframework` from Finder onto the **Vox** project icon in Xcode's project navigator.
   - Uncheck **Copy items if needed**, ensure **Vox** target is selected, click **Finish**.
   - Target → **General** → **Frameworks, Libraries, and Embedded Content** → set the framework's mode to **Embed & Sign**.

5. **Build & run** (⌘R).

### Updating to a newer whisper.cpp

```sh
cd ~/Codeplace/whisper.cpp
git pull
./build-xcframework.sh
cp -R build-apple/whisper.xcframework ~/Codeplace/vox-macos/Vox/Frameworks/
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
- [x] **Phase 6** — polish. Pulsing menu bar icon during recording, floating overlay HUD (recording + transcribing states), error alerts (no model, mic denied, recording failed, transcription failed, download failed, accessibility missing), launch at login, transcription timing logs, settings persistence audit, download validation, temp file cleanup, model directory migration.
- [x] **Phase 7** — distribution. Signed with Developer ID, notarized via Apple, Hardened Runtime enabled.

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
| `snippets` | Data (JSON) | `[]` | Array of `{id, trigger, replacement}` for find/replace |
