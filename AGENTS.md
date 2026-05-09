# AGENTS.md

Context for AI coding assistants working in this repo.

## What this project is

A native macOS menu-bar dictation app. Tap a global hotkey to start recording, tap again to stop → audio is transcribed and pasted into the focused window. Transcription is done locally via whisper.cpp. See `README.md` for the full goals list.

## Tech choices (locked in)

- **Language:** Swift 5.9+.
- **UI:** SwiftUI for the settings window and `MenuBarExtra`. AppKit only where SwiftUI can't reach (global hotkeys, synthesized keystrokes).
- **Min target:** macOS 15. Gives us current SwiftUI APIs and is recent enough that sandbox + Accessibility behaviour is well-documented and predictable.
- **Sandboxed.** The app runs under App Sandbox. This costs us nothing functionally (Accessibility-driven ⌘V, global hotkeys, and microphone all work in sandbox once the user grants the relevant permissions) and keeps the Mac App Store as a future option.
- **IDE:** Xcode. The project is an Xcode app target, not a SwiftPM executable, because we need an `.app` bundle, `Info.plist`, entitlements, and a menu-bar `LSUIElement` flag.
- **Whisper integration:** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) via a locally-built XCFramework. The user clones `whisper.cpp` next to this repo, runs `./build-xcframework.sh`, and copies the resulting `whisper.xcframework` into `Vox/Frameworks/`. The framework is gitignored. See `README.md` § "Building from source" for the exact steps. Swift code does `import whisper` (lowercase — that's the module name baked into the upstream xcframework's modulemap). Our app target is `Vox`, so no collision. Models downloaded at runtime, not bundled.
- **Global hotkey:** [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) SPM package. Wraps Carbon `RegisterEventHotKey` and gives us a SwiftUI recorder view for the settings screen.
- **Audio capture:** `AVAudioEngine`, resampled to 16 kHz mono Float32 (whisper's expected input).
- **Paste mechanism:** write to `NSPasteboard.general`, synthesize ⌘V via `CGEvent`, restore previous pasteboard contents after a short delay.

## Hard constraints

- **No network calls** for transcription or telemetry. Model downloads from Hugging Face are the only allowed network use.
- **No transcription history on disk.** The pasted text must not be persisted. Logs must not include transcribed content.
- **No dock icon.** `LSUIElement = true` in `Info.plist`. The app is menu-bar only.
- **Restore the pasteboard** after pasting so we don't clobber whatever the user had copied.

## Entitlements

The app is sandboxed. The following entitlements must be set on the target:

| Entitlement | Required for |
|---|---|
| `com.apple.security.app-sandbox` | The sandbox itself. |
| `com.apple.security.device.audio-input` | Microphone capture via `AVAudioEngine`. |
| `com.apple.security.network.client` | Outbound HTTPS to Hugging Face for model downloads. |
| `com.apple.security.files.user-selected.read-write` | Only if/when we expose an "Import custom model…" file picker. Skip until that feature lands. |

Things that do **not** need an entitlement:
- `CGEventPost` for the synthesized ⌘V keystroke — gated by the user-granted Accessibility permission, not by sandbox.
- Carbon `RegisterEventHotKey` — works inside the sandbox.

## Locked design decisions

- **Hotkey** — toggle style. Tap to start recording, tap again to stop and transcribe.
- **Paragraph splitting** — both: silence-gap detection (~1.5s threshold, configurable) *and* preserve whisper's own sentence/paragraph output.
- **Custom dictionary** — bias via whisper's `initial_prompt` only. User-entered names/spellings are joined into the prompt before each transcription. No post-processing find/replace in v1.
- **Model storage** — no bundled model. Downloader is part of v1, not a later phase. Because the app is sandboxed, models live inside the container at `~/Library/Containers/<bundle-id>/Data/Library/Application Support/vox-macos/models/`. Resolve this path via `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)` — never hard-code. First-launch flow shows the user the model list (sizes + quality notes) and downloads their pick from Hugging Face (`ggml-org/whisper.cpp` repo, `ggml-*.bin` files). For phased development, devs can drop a `.bin` into that container folder manually and the app should pick it up.
- **Distribution** — GitHub Releases, unsigned by default. The build pipeline should be structured so that adding a Developer ID + notarization later is config-only, not a code change.

## Repo layout

The Xcode project lives in a `Vox/` subdirectory at the repo root. This keeps the root usable for non-source artifacts (docs, CI, release scripts, future Swift packages). The double-`Vox/` (project folder containing a source folder of the same name) is the standard Xcode template layout — cosmetically odd, functionally fine.

```
vox-macos/
├── README.md
├── AGENTS.md
├── .gitignore
└── Vox/
    ├── Vox.xcodeproj/
    └── Vox/
        ├── App/                 # entry point, MenuBarExtra, Settings scene
        ├── Audio/               # AVAudioEngine recorder, resampler
        ├── Transcription/       # whisper.cpp wrapper
        ├── ModelManager/        # download + select whisper models
        ├── Hotkey/              # KeyboardShortcuts integration
        ├── Paste/               # pasteboard + CGEvent keystroke
        ├── Postprocess/         # dictionary biasing, paragraph splitting
        ├── Settings/            # SwiftUI settings views (General, Model, Dictionary tabs)
        └── Assets.xcassets
```

If/when a module grows big enough to be reusable or independently testable (e.g. `Transcription` or `ModelManager`), promote it to a Swift Package under a top-level `Packages/` directory next to `Vox/`. No restructuring of the existing layout needed.

## Conventions

- Keep files small and feature-scoped — one concept per file.
- Prefer `actor` / `async` over GCD for concurrency.
- No third-party deps beyond `whisper.cpp` and `KeyboardShortcuts` without discussion.
- No comments restating what the code does. Comments are reserved for non-obvious *why* — e.g. the pasteboard-restore delay, whisper sample-rate requirement.

## Things that will trip you up

- **Accessibility permission** is required to send ⌘V. The app must check `AXIsProcessTrustedWithOptions` and prompt the user on first run. This is independent of sandbox; the user grants it in System Settings → Privacy & Security → Accessibility.
- **Microphone permission** must be requested before the first recording, not at launch. Sandboxed apps still hit the standard `AVCaptureDevice.requestAccess` flow.
- **Pasteboard restore timing** — if you restore too quickly the synthesized ⌘V pastes the *old* contents. Needs a small delay (~100–200 ms) after the keystroke.
- **Whisper sample rate** — whisper.cpp requires 16 kHz mono Float32. AVAudioEngine's default tap format is the device's native rate; resample before passing to whisper.
- **Menu bar app lifecycle** — `LSUIElement` apps don't get standard window/quit menus for free. Settings window has to be opened explicitly from the menu bar item.
- **Sandbox container paths** — every path that lands on disk (models, caches, logs) must resolve through `FileManager` APIs. Hard-coded `~/Library/Application Support/...` will silently miss the container redirect and either fail or read the wrong folder.

## Out of scope (do not build)

- Any kind of cloud sync, account, or telemetry.
- LLM-based rewriting of the transcript.
- Live streaming captions.
- Transcription history UI.
