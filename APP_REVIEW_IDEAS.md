# Spokium App Review And Ideas

Reviewed on May 23, 2026.

Scope: current macOS app code, product ideas, privacy/security posture, and technical recommendations. Completed ideas from earlier notes were re-checked against source before this pass. Rejected ideas stay in `REJECTED_IDEAS.md` and should not be re-added unless explicitly revisited.

## Current Strengths

- Core flow is coherent: menu-bar hotkey -> temp audio recording -> local whisper.cpp inference -> snippets -> pasteboard/Command-V paste.
- Privacy posture is strong: no cloud transcription, no telemetry, no transcript logging, no transcript history, and model downloads are the only app network path.
- The sandbox, audio input, network client entitlement, Hardened Runtime, and `LSUIElement` menu-bar behavior fit the app's goals.
- Settings cover the important daily controls: language, model, hotkey mode, input device, launch at login, auto-stop, paragraph splitting, auto-paste, clipboard restore, dictionary, snippets, sounds, and paste permission readiness.
- Model downloads validate HTTP status, GGML magic bytes, and SHA-1 checksums before accepting a file.
- Paste failure behavior is user-preserving: when Accessibility is missing, the transcript stays on the clipboard and the menu keeps a non-sensitive remediation row.

## Applied Since Earlier Recommendation Passes

These should not remain as roadmap items unless a new bug is found:

- Live level meter in the overlay.
- Esc/menu cancellation, including whisper abort during normal in-flight cancellation.
- Auto-stop recording limit.
- Start/paste/empty sound effects behind the `playSounds` setting.
- Clipboard-only mode and paste feedback overlay.
- Accessibility preflight and persistent menu remediation for paste failures.
- Disk usage display and manual model hash verification.
- Snippets and dictionary token counting.
- Menu-based input-device and model selection.
- Temp audio cleanup for normal cancel/start/configuration/transcription paths.
- `starting` state to protect against double-start races.
- Atomic callback flags for audio write failures, audio levels, and whisper aborts.
- Hardened download cancellation.
- CoreAudio input-device fallback logging.
- `playSounds` added to the documented defaults tables.
- Queued transcription pipeline: new recording starts immediately while previous audio transcribes in background; results concatenated and pasted as one.
- Mid-recording microphone switching with seamless segment handoff; previous segment saved and queued for transcription before new device starts.
- Device disconnect recovery: on failure to resume after a device change, falls back to system default mic and continues recording.
- Per-model real-time-factor metadata stored as aggregate count + durations only (never text), displayed in the Model tab.
- File-level split of `SettingsView.swift`, `RecordingController.swift`, and `AppDelegate.swift` into per-tab files and per-concern extensions, plus a new `MenuBar/` + `Recording/` folder organisation. Largest source file is now ~260 lines (was 736). Shared stored properties on `RecordingController` and `AppDelegate` are now at default (internal) visibility to allow same-type extensions in sibling files.
- `SpokiumTests` target added (Swift Testing). First batch of pure-logic tests covers `SnippetStore.apply`, `SilenceDetector.breaks`, `DictionaryPromptBuilder.prompt`, and `WhisperModel.validateFile`. 31 tests, all passing.
- Pure helpers extracted to make the above testable: `Transcription/SilenceDetector.swift` (lifted out of `Transcriber` actor) and `Transcription/DictionaryPromptBuilder.swift` (deduped the entry-parsing logic that previously lived in both `RecordingController+Transcription` and `DictionaryTab`).
- Typed settings layer: `Settings/AppDefaults.swift` centralises every persisted key (as `DefaultsKey.x` constants) and every typed accessor (`AppDefaults.x` with `AppDefaults.xDefault` fallbacks). All call sites — including `@AppStorage` in SwiftUI views — now go through these. Eliminates stringly-typed defaults bugs across the codebase. Stores like `Snippets` and `ModelPerformanceStore` keep their own JSON encode/decode but reference `DefaultsKey` for their keys.
- `RecordingController.cleanup()` now aborts whisper inference, stops the active recorder, and deletes pending segment files before unloading the transcriber — fixes the "quit during inference waits for whisper" gap.
- Stage 1 of session-orchestration extraction: `RecordingMonitors` owns the timer/monitor vars (level polling, auto-stop, Esc keyDown) with a closure-callback API. `RecordingController` exposes `startSegmentMonitors` / `stopSegmentMonitors` / `startEscape` wrappers.
- Stage 2 of session-orchestration extraction: `TranscriptionQueue` owns the serial chain (`lastTask`, `activeTasks`), queue accounting (`pendingCount`, `pendingAudioSeconds`, `currentStartedAt`), and the `Transcriber` actor instance. Exposes `enqueue(..., onComplete:, onIdle:)` so `RecordingController` can be notified per-transcription and on drain. `RecordingController` lost six more stored properties; `transcribeSession` moved into the queue. Stage 3 (`SegmentCoordinator`) still queued.
- Snippet matcher upgraded from `\b...\b` to Unicode-aware lookarounds `(?:^|(?<=\W))...(?:$|(?=\W))`. Triggers with leading or trailing non-word characters (`C++`, `Mr.`, `#hello`, etc.) now match correctly; Unicode triggers (`café`, `日本語`) and word-bounded ones still match as before.
- Test target expanded from 43 to 73 tests: added `AudioLoaderTests` (sine-wave fixtures generated at test time, no checked-in binaries), `WhisperModelTests` (metadata sanity), and edge-case batches for `SilenceDetector` (odd sample rates, exact-threshold, zero-rate guard) and `SnippetStore` (Unicode, embedded punctuation, boundary triggers).
- Removed the user-facing auto-split setting. It was a configurable knob with no observable effect — split segments accumulated locally and were concatenated back into one whisper call on stop, so the user saw zero benefit. Mid-session segment splitting still exists internally for the device-switch handoff path (`splitCurrentSegment` driven by `handleAudioConfigurationChange`), but is no longer timer-triggered. Removed: `DefaultsKey.autoSplitMinutes`, `AppDefaults.autoSplitMinutes(Default)`, the General-tab picker, and `RecordingMonitors.startSplit` / `stopSplit`.
- Opt-in `TranscriptHistory` (default off): in-memory store of the last 5 transcripts with 5-minute retention, surfaced as a "Recent Transcripts" submenu in the menu bar. Click to copy; "Clear History" at the bottom. Never serialised; cleared on quit, on toggle-off, and on demand. Privacy posture preserved: opt-in, memory-only, capped, ephemeral.
- Hidden debug mode (`defaults write com.spokium.mac debugMode -bool true`). No UI surface. When on: audio files are moved to a sandbox `debug-recordings/` folder (100 MB cap, oldest dropped) and a markdown sidecar with per-segment whisper output (text + `no_speech_prob` + timestamps) is written next to each one. No system-wide logging — all debug data lives in that one folder. A "Reveal Debug Folder" item appears in the menu bar. Disabling wipes the folder via a `UserDefaults` observer + launch-time idempotent cleanup. Documented in README.md, SECURITY.md, AGENTS.md, docs/code-audit-map.md.
- Compact queue/status menu section: the menu bar dropdown shows "Recording 0:12" / "Transcribing ~3s left" / "Transcribing 2" rows that derive from durations and counts only — no transcript content. Refreshes on a 1 Hz timer while the menu is open.

## Highest-Priority Technical Changes

1. Decide what to do with the checked-in `whisper.xcframework`.
   - The current repo has `Spokium/Frameworks/whisper.xcframework` tracked in Git, while older docs described it as local/generated.
   - Either keep it intentionally and document framework provenance, or untrack it and make the build-from-source workflow mandatory.
   - If kept, release validation should hash the embedded framework and record the upstream whisper.cpp commit used to build it.

## Architecture Refactors

1. Continue session-orchestration extraction.
   - Stages 1 (`RecordingMonitors`) and 2 (`TranscriptionQueue`) are done. Stages remaining:
     - **Stage 3 — `SegmentCoordinator`**: would own segment URLs, Continuity Mic retry loop, device-disconnect fallback. Riskiest because the Continuity Mic edge cases are subtle.
     - Optional: `TempRecordingStore` for temp-file lifecycle.
   - Each stage needs a manual record-stop-paste + Esc-cancel smoke test by the user since there are no integration tests.

2. Add dependency injection for side-effectful services.
   - Wrap recorder, transcriber, paste, defaults, model lookup, clock/timers, sounds, and file cleanup behind small protocols.
   - Keep production construction simple; the goal is tests, not an abstract framework.

3. Revisit `NSHostingSceneRepresentation` settings injection.
   - `SettingsSceneRoot` safely falls back to a placeholder, but reaching through `NSApp.delegate` from a settings view is still coupling.
   - Prefer an explicit settings scene opener or environment object if the pattern grows.

## Technical Improvements

1. Avoid whole-file audio loading for long recordings.
   - `AudioLoader.loadResampled(url:)` reads the full source file into memory and returns all samples as one array.
   - This is acceptable for short dictation, but risky with 30-minute or no-limit recordings.
   - Either enforce a hard maximum duration/size or move toward chunked conversion.

2. Add CI or a local validation script.
   - Start with build, entitlements, `LSUIElement`, linked frameworks, generated docs, and suspicious-pattern greps.
   - The test target now runs 73 tests in <2s; wiring it into CI is the next step.

3. Add release provenance checks.
   - Verify Developer ID signing, notarization, Hardened Runtime, entitlements, and embedded framework hash.

4. Make model verification state actionable.
   - Current verification marks failed models as unavailable in memory but does not offer repair beyond manual deletion/download.
   - Add a "Delete failed files" or "Redownload failed models" action.

5. Add explicit no-speech handling thresholds to tests.
   - `Transcriber` filters segments with `no_speech_prob > 0.6`.
   - Keep that behavior documented and tested so future whisper.cpp updates do not make empty recordings paste stray text.

6. ~~Loop / hallucination detection + retry-with-temperature.~~ **Done.** Implemented as `LoopDetector` (segment-level, ≥5 consecutive identical kept segments). Real debug folder examples showed the loop emits identical *segments* over and over (no shared `". "` boundary), so the trailing-suffix split heuristic in the original spec was abandoned in favour of byte-equal segment-run detection. On detection, `Transcriber` retries once at `params.temperature = 0.4`; if the retry still loops, the text is dropped to empty and the user sees the existing `.empty` `CompletionFeedback`. Tuning context lives in `LoopDetectorTests`.

7. Investigate "no speech detected" false positives.
   - Symptom: level meter clearly showed audio during recording, but Spokium reports "No speech detected" and pastes nothing.
   - Likely cause: `no_speech_prob > 0.6` filter in `Transcriber.keptSegmentIndices` is too aggressive for quiet/whispered speech or unusual mics.
   - Possible fixes: raise threshold to 0.8 or 0.9; make it configurable; or compute filter decision per-recording based on the distribution of segment probabilities.
   - **Also gated on debug-mode data.** The sidecar markdown files in `debug-recordings/` include per-segment `no_speech_prob` — once a real false-positive example is captured there, we can see whether the segments were filtered, where the threshold sits in that case, and tune accordingly.

8. Stop probing Bluetooth devices for input streams on every menu open.
   - Symptom (observed live): selecting a Bluetooth headset as Spokium's input degrades currently-playing music's quality immediately, before any recording starts. The trigger is actually menu *open*, not selection — perception lags.
   - Cause: `AudioInputDevice.available()` (Spokium/Audio/AudioDevices.swift) calls `hasInputChannels(id)` on every CoreAudio device, which queries `kAudioDevicePropertyStreamConfiguration` on input scope. On many BT stacks this probe is enough to switch the device to HFP/SCO profile (the low-quality one that exposes a mic), since the daemon treats "tell me your input streams" as "I'm about to read from you". The profile then stays in HFP for a while before A2DP returns. Spokium runs `available()` on every menu refresh, so any time the user pokes the menu while listening to music, audio quality drops.
   - Spokium itself never opens the device for capture outside `AudioRecorder.start()` (line 50). The mic is *not* continuously tapped — it's the metadata probe that wakes the BT input side.
   - Proposed fix: keep a cached device list, invalidate on signal rather than on every menu open. Defense-in-depth:
     1. **Primary:** `AudioObjectAddPropertyListener` for `kAudioHardwarePropertyDevices` → refresh cache on every callback.
     2. **Cheap freshness check on menu open:** read the bare AudioDeviceID list (`kAudioHardwarePropertyDevices`, just IDs — no per-device stream config query, so no BT activation). If the ID set matches the cache, serve cache; only re-probe when the ID set differs.
     3. **Wake handling:** subscribe to `NSWorkspace.didWakeNotification`, invalidate the cache (don't probe immediately — let the next menu open do it via #2).
   - Net effect: cold-start probe happens once at app launch; subsequent menu opens read the cache; full re-probe only happens when CoreAudio actually says devices changed. BT music quality is no longer affected by opening Spokium's menu.
   - Adjacent cleanup: the same cache should drive `GeneralTab.Picker("Input device:")` so opening Settings doesn't re-trigger the probe either.

## Functional Feature Ideas

1. Better model lifecycle controls.
   - Delete model from menu.
   - Redownload corrupt model.
   - Show model path and checksum in an advanced disclosure.

2. Accessibility onboarding without a full first-run panel.
   - Keep the rejected first-run readiness panel out.
   - A lightweight inline Settings row already exists; consider a menu action that opens the same permission affordance only after paste fails.

3. Meeting audio capture (Zoom, Teams, etc.).
   - macOS does not expose app audio as a recordable input natively.
   - ScreenCaptureKit (`SCStream`, macOS 13+) can capture audio from a specific app process without third-party drivers. Requires Screen Recording permission entitlement.
   - Implementation: `SCContentFilter` targeting the meeting app process, `SCStream` with `capturesAudio: true`, PCM buffers fed alongside mic input, mixed float arrays passed to Whisper.
   - Alternative requiring no code: user installs BlackHole virtual audio driver and routes meeting app output through it, then picks BlackHole as Spokium's input device.
   - This is a meaningful product direction shift toward meeting transcription; worth a deliberate decision before starting.

## Parked / Not Recommended Under Current Constraints

- Cloud transcription, telemetry, accounts, or sync.
- Persistent transcription history UI (the opt-in memory-only `TranscriptHistory` is the agreed compromise).
- LLM-based rewriting of transcripts.
- Live streaming captions as a primary feature. Partial preview is interesting but conflicts with the current "short dictation -> final pass -> paste" app shape and adds real complexity around incremental audio, GPU contention, cancellation, and UI churn.
- App automation features such as pausing Music/Spotify when recording. They would push Spokium toward Apple Events or broader event synthesis and weaken the current security story. (Exception accepted 2026-11-08: "Quiet while recording" — bare POST/DELETE to URLs the user enters, local network only; see AGENTS.md.)
- Salting `initial_prompt` with a neutral phrase to dodge whisper hallucinations. Less principled than the temperature retry fallback; same effect with more unpredictability. Revisit only if temperature retry isn't enough.

## Delivered Phases (historical)

Moved out of `README.md` to keep the user-facing doc lean. Useful as a delivery log for reviewers and for tracking what's already shipped.

All core functionality is implemented and working:

- [x] **Phase 1** — menu-bar shell. `NSStatusItem` with red pulsing waveform icon while recording, Settings scene with five tabs (General, Transcription, Model, Dictionary, Snippets). Menu bar dropdown also exposes input device and model submenus.
- [x] **Phase 2** — hotkey + audio capture. `KeyboardShortcuts` SPM, default ⌥Space, toggle or push-to-record mode, `AVAudioEngine` records native-rate `.caf` to the sandbox's tmp dir. Input device selectable from menu bar and Settings.
- [x] **Phase 3a** — transcription wired. On stop: resample to 16kHz mono → run whisper inference → output text with language detection. Audio file auto-deleted after transcription. Whisper context cached across sessions for fast re-transcription. GPU fallback to CPU if GPU init fails.
- [x] **Phase 3b** — model picker UI. Settings → Model tab lists 6 models (tiny through large-v3-turbo), downloads from Hugging Face with progress bar, validates with SHA-1 checksums and GGML magic bytes. "Show in Finder" button for manual model management.
- [x] **Phase 4** — paste pipeline. Save current pasteboard, write transcript, synthesize ⌘V via `CGEvent`, optionally restore previous pasteboard after 150ms. Configurable auto-paste and clipboard restore settings.
- [x] **Phase 5** — post-processing. Custom dictionary biasing via whisper's `initial_prompt` with real token counting (224 max). Paragraph splitting via RMS-based silence detection on recorded audio (configurable threshold). User-defined snippets find/replace after transcription.
- [x] **Phase 6** — polish. Pulsing menu bar icon during recording, floating overlay HUD with live audio level meter (mic icon fills red bottom-up) and brief pasted / copied / no-speech-detected confirmation, cancel-anytime via Esc or menu (uses whisper's abort callback for true mid-flight interruption), auto-stop after configurable time limit, error alerts plus a persistent error row in the status menu (no model, mic denied, recording failed, transcription failed, download failed, accessibility missing) with a one-shot "Turn Off Auto-paste" remediation for paste failures, Accessibility-permission preflight in Settings and before each ⌘V synth, launch at login, sound effects, transcription timing logs, settings persistence audit, download validation, temp file cleanup, model directory migration. `LSUIElement` stays enabled so no Dock icon appears.
- [x] **Phase 7** — release pipeline. Builds are archived in Xcode, exported with `method = developer-id`, notarized via Apple's `notarytool`, and stapled before publication as `.zip` artifacts on GitHub Releases. Hardened Runtime is enabled in the target build settings.

### Settings (UserDefaults keys)

| Key | Type | Default | Description |
|---|---|---|---|
| `selectedLanguage` | String | `"auto"` | Whisper language code or `"auto"` for detection |
| `paragraphSplitting` | Bool | `true` | Insert paragraph breaks on silence gaps |
| `silenceThreshold` | Double | `3.0` | Seconds of silence to trigger a paragraph break |
| `autoPaste` | Bool | `true` | Simulate ⌘V after transcription |
| `preserveClipboard` | Bool | `true` | Restore clipboard after paste |
| `dictionaryEntries` | String | `""` | Newline-separated custom names/spellings |
| `selectedModel` | String | (auto) | Name of the selected whisper model |
| `selectedInputDevice` | String | `""` | Audio input device UID (empty = system default) |
| `pushToRecord` | Bool | `false` | If true, hold shortcut to record instead of toggle |
| `playSounds` | Bool | `false` | Play system sound effects for recording start, paste/copy, and empty result |
| `snippets` | Data (JSON) | `[]` | Array of `{id, trigger, replacement}` for find/replace |
| `maxRecordingMinutes` | Double | `10` | Auto-stop recording after N minutes (0 = no limit) |
