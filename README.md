# vox-macos

A small, native macOS dictation helper. Tap a global keyboard shortcut to start recording, tap again to stop — the transcribed text is pasted into whatever window is focused. Powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp) running fully on-device.

## Goals

- **Native, lightweight.** Single Swift app, no Electron, no background daemon zoo.
- **Lives in the menu bar.** No dock icon. The status item shows idle / recording / transcribing state.
- **Global hotkey to record.** Toggle style: tap to start recording, tap again to stop, transcribe, and paste.
- **On-device only.** All audio and transcription stays local; no network calls.
- **Settings window** for: language, model size (tiny / base / small / medium / large), microphone selection, hotkey, and a custom dictionary (names + spellings to bias the model and/or post-process).
- **Paragraph splitting.** Long pauses become paragraph breaks so pasted output keeps structure instead of being one long blob.
- **Pastes into the active window.** Uses the system pasteboard + a synthesized ⌘V. No history kept; the previous clipboard contents are restored after paste.
- **No transcription history.** Nothing is saved to disk after the paste.

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
│  MenuBarExtra ──► status icon, quick toggles, open settings │
│  Settings scene ──► language, model, hotkey, dictionary     │
│                                                             │
│  ModelManager ──► download / list / select whisper models   │
│        │                                                    │
│        ▼                                                    │
│  HotkeyManager ──► global toggle shortcut (tap on/off)      │
│        │                                                    │
│        ▼                                                    │
│  AudioRecorder (AVAudioEngine) ──► 16kHz mono PCM buffer    │
│        │                                                    │
│        ▼                                                    │
│  Transcriber (whisper.cpp via SwiftPM) ──► text + timings   │
│        │                                                    │
│        ▼                                                    │
│  Postprocessor ──► dictionary fixes, paragraph splitting    │
│        │                                                    │
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
- **Accessibility** — required to synthesize the ⌘V keystroke. User grants this in System Settings → Privacy & Security → Accessibility. Works inside the sandbox.

## Decisions

- **Paragraph splitting** — combine both signals: insert a paragraph break on a silence gap above ~1.5s, *and* preserve any sentence/paragraph structure whisper emits.
- **Custom dictionary** — bias recognition via whisper's `initial_prompt`. The user's custom names/spellings are concatenated into the prompt so the model is more likely to produce them. (No post-processing find/replace in v1.)
- **Model storage** — no bundled model. The app downloads models on demand into its sandbox container at `~/Library/Containers/<bundle-id>/Data/Library/Application Support/vox-macos/models/`. On first launch the user picks a default model from a list (size + estimated quality shown), and we fetch it from Hugging Face (`ggml-org/whisper.cpp`). During phased development, models can also be dropped into that folder manually.
- **Distribution** — personal use, published as `.zip` builds on GitHub Releases. Unsigned in v1; users right-click → Open the first time (or `xattr -d com.apple.quarantine` it). May revisit if/when an Apple Developer ID license is purchased — the same code path supports a signed + notarized build.

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

## Status & roadmap

Goal in one sentence: **tap a global hotkey, speak, tap again, the transcript pastes into the focused window.** Local-only, sandboxed, no history.

Phases:

- [x] **Phase 1** — menu-bar shell. `NSStatusItem` (custom-rendered SwiftUI view, red pill background while recording), Settings scene with three tabs (General, Model, Dictionary).
- [x] **Phase 2** — hotkey + audio capture. `KeyboardShortcuts` SPM, default ⌥Space toggle, `AVAudioEngine` records native-rate `.caf` to the sandbox's tmp dir.
- [ ] **Phase 3a** — transcription wired. `Transcription/{Transcriber,AudioLoader,ModelLocator}.swift` are written; on stop the controller resamples → calls whisper → logs `Transcript: …`. Audio file is auto-deleted after.
  - Pending: apply the Xcode setup from § *Initial Xcode project setup* and § *Building from source*, then drop a model `.bin` into `~/Library/Containers/com.bartoszadamczyk.Vox/Data/Library/Application Support/vox-macos/models/` (the app prints this exact path to the Xcode console if no model is found). End-to-end test: tap ⌥Space, speak, tap, see the transcript in the console.
- [ ] **Phase 3b** — model picker UI. Settings → Model tab lists available + downloadable models, downloads from Hugging Face on demand, persists the selected model in `UserDefaults`.
- [ ] **Phase 4** — paste pipeline. Save current pasteboard, write transcript, synthesise ⌘V via `CGEvent`, restore previous pasteboard after ~150 ms. Handle Accessibility permission prompt on first use.
- [ ] **Phase 5** — post-processing. Custom dictionary biasing via whisper's `initial_prompt` (Settings → Dictionary tab), paragraph splitting from silence gaps (~1.5 s threshold) detected on the recorded buffer.
- [ ] **Phase 6** — polish. Animated recording icon, error toasts/alerts when no model / transcription fails, settings persistence audit, optional Developer ID signing + notarisation for GitHub Releases distribution.

### Immediate next actions for whoever picks this up

1. Verify the Xcode project state matches § *Initial Xcode project setup* — diff what's missing and apply it.
2. Verify the framework is wired per § *Building from source* (Phase 3a depends on it).
3. Run the app, hit ⌥Space twice, and read the Xcode console — either you'll see a transcript or an error log telling you what's missing.
4. Once 3a is green, start Phase 3b.
