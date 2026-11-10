# Spokium for MacOS

A small, native macOS dictation helper. Tap a global keyboard shortcut to start recording, tap again to stop — the transcribed text is pasted into whatever window is focused. Powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp) running fully on-device.

## Goals

- **Native, lightweight.** Single Swift app, no Electron, no background daemon zoo.
- **Lives in the menu bar.** No dock icon (ever, including when Settings is open). The status item shows idle / recording / transcribing state with a pulsing red waveform icon while recording.
- **Global hotkey to record.** Toggle style (default ⌥Space): tap to start recording, tap again to stop, transcribe, and paste. Push-to-record mode also available (hold while speaking, release to transcribe).
- **On-device only.** All audio and transcription stays local. The only network use is model downloads from Hugging Face and, if you set it up, the optional *Quiet while recording* requests to devices on your own network.
- **Transcribes while you talk.** Speech is cut into short chunks at natural pauses and transcribed as you go, so even a long dictation pastes about a second after you stop. Chunks overlap where no pause is found, and the seams are de-duplicated using word timestamps.
- **Voice detection.** A bundled [Silero VAD](https://github.com/snakers4/silero-vad) model (0.9 MB, via whisper.cpp) tells speech from typing, clicks and room noise. It decides where to cut chunks and where paragraphs break; silence-only recordings skip whisper entirely. Quiet speech and whispering are kept even when the detector isn't sure.
- **Languages that mix.** One menu: *Any language*, one language (forced), or several. With several, detection stays free, so mixed Polish/English speech stays mixed, and a phrase detected as a language you don't speak is redone in your main one. Settings shows how much you use each language (counts only, never text).
- **Flat-output fix.** When whisper returns a long run of lowercase words with no punctuation, the chunk is redone once with a punctuated example sentence in the prompt.
- **Menu bar dropdown** with quick switching for input device, active whisper model and quiet device (no need to open Settings for routine changes).
- **Sensible microphone handling.** The device list is cached, so opening the menu no longer drops Bluetooth headphones into low-quality call mode. When the mic you're using disappears, the selection moves to the next best one (built-in → wired → Bluetooth/iPhone) and the menu shows it, so you can correct it before the next recording.
- **Voice commands for line breaks.** "New line" and "new paragraph" are built-in snippets; type `\n` in any snippet replacement for a line break.
- **Snippets.** Define spoken triggers like "calendar link" that get replaced with arbitrary text on paste. Case-insensitive, whole-word matching.
- **Live audio level meter.** Recording overlay shows a microphone icon that fills red from the bottom up based on input volume — instant feedback that the mic is working.
- **Dead-mic detection.** Catches the common case where `AVAudioEngine` starts but no audio actually flows (e.g. built-in mic with the lid closed — the mic sits in the lid hinge — or AirPods/Continuity that never wake up). Levels are sampled continuously; if 5s pass with no signal at all, the HUD swaps to an orange "No audio — check microphone" warning and a Sosumi alert chime plays once. If audio later resumes, the HUD reverts to the normal level-meter "Recording" state. The warning is one-shot per take — once it has fired and recovered, it stays dismissed until the next mic switch or the next recording, so slow-waking inputs and long pauses don't spam the alert. On stop, the `.caf` file is also verified to exist and be non-empty before the transcription path runs, so a dead recording surfaces as a real error instead of silently producing an empty transcript.
- **Cancel anytime.** Press Shift+Esc (or the menu item) to discard a recording or abort an in-flight transcription. Whisper's abort callback is wired up, so cancelling during inference actually stops compute.
- **Auto-stop after time limit.** Configurable maximum recording duration (10, 20, 30 min, 1 h or no limit; default 30 min) prevents accidentally leaving the hotkey on forever.
- **Quiet while recording (Integrations).** Add devices such as a home-made radio by URL; the selected one gets a `POST` when recording starts (repeated every 20 s to extend its mute) and a `DELETE` when you stop. No body, nothing about the recording is sent. Pick the device for the room you're in from the menu.
- **Settings window** with tabs for General (shortcut, push-to-record, input device, launch at login, sound effects, auto-stop), Transcription (language, live transcription, paragraph splitting), Output (auto-paste, clipboard restore, recent transcripts), Model (download, select, Neural Engine encoders, speed stats), Dictionary (with token counting), Snippets and Integrations.
- **Optional Neural Engine encoders.** Each downloaded model can get a Core ML encoder (Settings → Model) that runs on the Apple Neural Engine — noticeably faster on Macs with smaller GPUs (e.g. M1/M2 Pro). The first use compiles it once, which can take a few minutes.
- **Paragraph splitting.** Detects pauses in your speech (configurable, default 4 s) and inserts paragraph breaks so pasted output keeps structure.
- **Pastes into the active window.** Uses the system pasteboard + a synthesized ⌘V. Optionally restores your previous clipboard 20 s later — long enough to paste the transcript manually if it landed in the wrong window — unless you copied something else meanwhile. Can also be set to clipboard-only mode (no auto-paste), with the same restore.
- **Paste feedback overlay.** After transcription the HUD briefly confirms the outcome — "Pasted" when auto-paste fires, "Copied to clipboard" when auto-paste is off, and "No speech detected" (with a soft chime) when the transcript came back empty. No transcript content is stored.
- **Accessibility preflight.** Settings → Output shows live paste readiness (granted / required) with a "Request Permission" button. The paste pipeline also preflights `AXIsProcessTrusted` before synthesizing ⌘V — without permission the transcript is left on the clipboard instead of dropping silently.
- **Persistent error row in the menu.** The status menu keeps a non-sensitive error message until the user dismisses it. For paste-permission failures it also surfaces "Open Accessibility Settings…" and a one-shot "Turn Off Auto-paste" remediation, so users can recover without digging through Settings.
- **No transcription history on disk.** Nothing is saved to disk after the paste. Logs do not include transcribed content. A "Keep recent transcripts" toggle (on by default, in Settings → Output) keeps the last 5 transcripts **in memory only** for 5 minutes so you can re-copy one if the paste landed in the wrong window. The history is cleared on app quit, manually via "Clear History" in the menu bar, and never touches disk.

## Non-goals

- Streaming / live captioning.
- Cloud transcription.
- A general voice-assistant UX (no commands beyond line breaks, no LLM post-processing).
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
│  AudioRecorder (AVAudioEngine) ──► 16 kHz live stream       │
│        │                          (+ native-rate CAF file)  │
│        ▼                                                    │
│  LiveChunker + Silero VAD ──► chunks cut at pauses          │
│        │                                                    │
│        ▼                                                    │
│  TranscriptionQueue ──► Transcriber (whisper.cpp actor)     │
│        │                                                    │
│        ├──► dictionary biasing (initial_prompt)             │
│        ├──► language fallback, loop + flat-output retries   │
│        ▼                                                    │
│  LiveTranscriptAssembler ──► seams, paragraphs, snippets    │
│        ▼                                                    │
│  Paster (NSPasteboard + CGEvent ⌘V) ──► active window       │
└─────────────────────────────────────────────────────────────┘
```

## Sandbox & permissions

The app runs under App Sandbox. Entitlements are generated from the Xcode target's Signing & Capabilities build settings, not from a checked-in `.entitlements` file. Required entitlements:

- `com.apple.security.app-sandbox`
- `com.apple.security.device.audio-input` — microphone
- `com.apple.security.network.client` — model downloads from Hugging Face, and Quiet while recording

User-granted permissions (prompted at first use, not at install):

- **Microphone** — backed by `NSMicrophoneUsageDescription` in `Info.plist`.
- **Local network** — only if you add a Quiet while recording device on your network. macOS asks once (`NSLocalNetworkUsageDescription`); plain `http` is allowed to the local network only (`NSAllowsLocalNetworking`), never to the internet.
- **Accessibility** — required to synthesize the ⌘V keystroke. User grants this in System Settings → Privacy & Security → Accessibility. Settings → Output surfaces a live readiness indicator with a "Request Permission" button so the grant can happen up front; if missing at paste time, the paste is skipped (transcript stays on the clipboard), an alert is shown, the system prompt is triggered, and a persistent menu row offers either "Open Accessibility Settings…", "Turn Off Auto-paste", or "Dismiss".

## Decisions

- **Paragraph splitting** — pauses are found with the Silero voice detector (RMS energy in 50 ms windows as a fallback). A pause above the configurable threshold (default 4 s) inserts a paragraph break between whisper segments, and between live chunks.
- **Custom dictionary** — bias recognition via whisper's `initial_prompt`. The user's custom names/spellings are concatenated into the prompt so the model is more likely to produce them. Dictionary entries are not find/replace rules; snippets handle post-transcription replacement.
- **Model storage** — no bundled whisper model (the only bundled model is the 0.9 MB Silero voice detector). The app downloads models on demand into the user Application Support directory, under `Spokium/models` as resolved by `FileManager` (inside the sandbox container for sandboxed builds). Settings → Model tab lists available models with size and quality info. Models are downloaded from Hugging Face (`ggerganov/whisper.cpp` repo) and validated with GGML magic bytes and SHA-1 checksums. Models can also be dropped into the folder manually via the "Show in Finder" button.
- **Download validation** — HTTP status code, GGML format magic bytes, and SHA-1 checksum verification before accepting a downloaded model.
- **Output options** — auto-paste (default on) and clipboard restore (default on) are independently configurable. With auto-paste off, text is placed on the clipboard only.
- **Snippets** — post-transcription find/replace. User-defined trigger phrases are matched against the transcript with case-insensitive whole-word matching, replaced before paste.
- **Loop hallucination guard** — greedy whisper sampling occasionally gets stuck emitting the same segment over and over (e.g. "1/2 tbsp vanilla extract" × 23, replacing the real audio). The `Transcriber` scans for ≥5 consecutive byte-identical kept segments; on a hit it retries the same audio once at `temperature = 0.4` (whisper.cpp's recommended fallback). If the retry still loops, the output is dropped to empty so the user gets the regular "No speech detected" HUD instead of a wall of repetition pasted into their editor.
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
| Build Settings | `INFOPLIST_KEY_NSLocalNetworkUsageDescription` | Quiet while recording explanation |
| `Spokium/Info.plist` | `NSAppTransportSecurity` → `NSAllowsLocalNetworking` | **YES** (merged with the generated plist) |
| Build Settings | `Swift Language Version` | **6.0** |
| Build Settings | `Default Actor Isolation` | **MainActor** |
| Signing & Capabilities | Hardened Runtime | ✓ (required for notarization) |

SPM dependency to add (File → Add Package Dependencies):
- `https://github.com/sindresorhus/KeyboardShortcuts` — global hotkey support, attached to the Spokium target

Framework to add: see § *Building from source* below.

## Debug mode (developers only)

Hidden developer affordance for diagnosing whisper hallucinations, repetition loops, and false-positive "no speech detected" cases. **Not exposed in Settings** — enable from the terminal:

```sh
defaults write com.spokium.mac debugMode -bool true
```

When on:
- Each transcription's audio file is **moved** to `~/Library/Containers/com.spokium.mac/Data/Library/Application Support/Spokium/debug-recordings/` instead of being deleted. The folder is size-capped at 100 MB (oldest files dropped first).
- A markdown sidecar (`{audio-basename}.md`) is written next to each audio file containing the per-segment whisper output: start/end timestamps, `no_speech_prob`, and the raw text. QuickLook-friendly; renders as a table in any markdown viewer.
- A **"Reveal Debug Folder"** item appears at the bottom of the menu bar dropdown.

No transcript text ever lands in OSLog or any system-wide log path. Everything debug-related sits in the one folder and disappears when you disable the flag.

Disable:

```sh
defaults write com.spokium.mac debugMode -bool false
```

On disable, the debug folder is wiped immediately by an in-process observer; a launch-time cleanup catches the case where the flag was flipped while the app wasn't running. Debug data never leaves the sandbox container and is never sent over the network. This is opt-in, sandboxed, and ephemeral by design — see `SECURITY.md` for the threat model.

## Building from source

The Xcode project links `Spokium/Frameworks/whisper.xcframework`. In this checkout the framework is present and tracked, but it is still treated as a rebuildable artifact from upstream `whisper.cpp`. If the framework is missing, stale, or you want to verify provenance, rebuild it from source:

1. **Clone whisper.cpp v1.9.5 as a sibling of this repo** (the version the app is built and tested against):
   ```sh
   cd ~/Codeplace          # or wherever this repo lives
   git clone --branch v1.9.5 https://github.com/ggml-org/whisper.cpp.git
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

Xcode picks up the updated framework on next build. Run `./scripts/check.sh` afterwards — it builds, runs the tests and checks the bundle.

## Releasing

`./scripts/release.sh <version>` runs the tests, bumps the build number, archives, notarizes, checks the notarized app with `scripts/check.sh` (signing, entitlements, no Dock icon, bundled voice-detection model, Gatekeeper) and installs it to `/Applications`. See `DEV.md` for the dev build and pre-release checks.

