# Spokium roadmap

The single place for what's next, open review findings, ideas, rejected ideas and past decisions. It replaces `plan.md`, `APP_REVIEW_IDEAS.md`, `CODE_REVIEW_2026-11.md` and `REJECTED_IDEAS.md` (all in git history). How things *work* is in `AGENTS.md`; this file is about what to do.

Rules for agents: don't re-propose anything under **Rejected** unless the user asks. Move items between sections rather than duplicating them.

## Next (agreed)

### L1 + L2: faster paste after stop

Baseline from logs: median ~1.2 s from stop to paste (0.34–2.6 s). The floor is the 300 ms stop tail plus engine teardown; the rest is transcribing the final chunk after the stop.

- **L1. Transcribe the tail speculatively.** When the queue is idle and the buffer ends in a pause of ~0.8 s, transcribe a snapshot of it without cutting. On stop, if no speech arrived after the snapshot, use that result as the final chunk; otherwise discard it (abort via the existing epoch when a real chunk arrives). Chunk boundaries are unchanged, so accuracy isn't affected; the cost is some extra GPU work. For "finish, breathe, press stop" this removes the whole post-stop transcription.
- **L2. Skip the stop tail when the user has already gone quiet.** The 300 ms tail exists for people who stop the instant they finish a word; if the live sink already shows ≥ 0.5 s of trailing silence, it buys nothing.

Together: most pastes ~0.1–0.4 s after the key press.

### A1: explicit session states + controller tests

The bugs fixed in Nov 2026 (stop tail race, early push-to-record release, stop during a device switch, lost first part of a continued session) were all interleavings that `state` plus side flags (`stopTailTask`, `isResumingAfterSplit`, `pendingStartCancel`, `pendingStop`, `isLiveSession`, `recorder.isRunning`) don't rule out, and none can be unit-tested because `RecordingController` builds its own recorder, queue and paster.

- Add the missing states (`.stopping` for tail + teardown, a "switching device" sub-state of recording); the HUD can keep mapping them to today's modes.
- Put recorder, queue, paste and clock behind small protocols; table-driven tests for: chunk completes during the tail, key-up during starting, cancel/stop during a device-switch resume, start failure in a continued session, sleep/lock during each state.

## Open review findings (to triage)

From the Nov 2026 code review; everything else in it is done (see **Done**).

- **File mode loads audio on the main thread.** With "Transcribe while recording" off, `TranscriptionQueue.run` reads and resamples the whole recording on the main actor; move the load into the `Transcriber` actor. Related known gap: file mode holds the whole recording in memory.
- **Selected model deleted in Finder** → "No Whisper Model" although others are downloaded; fall back to any downloaded model. "Verify Hashes" deletes on a read error, not only on a mismatch.
- **Debug-mode wipe isn't immediate** after a terminal `defaults write` (`UserDefaults.didChangeNotification` doesn't fire across processes; KVO on the key would).
- **Settings device list goes stale** — `GeneralTab` loads devices once; observe `.audioInputDevicesChanged`.
- **R2** Live mode has no fallback if `LiveResampler` can't be built (session ends as "No speech" while a good file is deleted). Check multichannel interfaces in the same pass (level meter reads channel 0 only).
- **R3** Close the `AVAudioFile` explicitly in `teardown()` instead of relying on deallocation order.
- **R4** Config changes in the first 2 s after start are ignored; afterwards check the engine is still running.
- **R5** Clean download leftovers (`<UUID>.download` up to 3 GB in tmp, `.unpack-<UUID>` in models) at launch.
- **R6** One app-level `ModelManager` instead of ~10 ad-hoc ones (menu selection doesn't update an open Settings; download progress may vanish when Settings closes — needs a check).
- **P2** Clipboard snapshot reads every type eagerly; cap the size above which restore is skipped.
- **P4** Models are checked with SHA-1, Core ML encoders with SHA-256; Hugging Face publishes SHA-256 for both. (Download URLs are pinned to a commit since 1.5.4.)
- **A2** Give `Transcriber` its own serial executor (each whisper run blocks a shared-pool thread).
- **A3** Live sessions still write a native-rate CAF used only by debug mode; keep the 16 kHz stream instead if retry (below) ever lands.
- **T3** Inference smoke test: synthesise a sentence at test time, run it through `Transcriber` with the tiny model, skip when absent.
- **Repo:** build only the macOS slice of `whisper.xcframework` (~67 of 82 MB are iOS/tvOS/visionOS); derive the log subsystem from the bundle ID (dev and production logs are indistinguishable today); `.gitignore` still lists `Vox/Frameworks/…` and ignores `docs/`.
- **Manual checks reading couldn't settle:** ⌘, with Settings focused (second window?); HUD over a full-screen app (`.fullScreenAuxiliary` missing); with sounds on, does the start chime ever reach whisper as audible content.

## Ideas (not committed to)

- **Radio list from the radios themselves** — announce over Bonjour or serve a list at one URL, so Spokium shows and ticks them instead of typing URLs. Specific to the user's own radio implementation (needs a radio-side protocol to know what is a radio).
- **Retry failed chunks** (was D5). A plain re-run is unlikely to help; it would need a different seed, temperature or chunk length. Today a failed live chunk leaves a hole in the text and an alert.
- **Out-of-list language with more context** — before forcing a language, re-transcribe the chunk merged with its neighbour and de-duplicate via word timestamps.
- **Adaptive keep threshold for very quiet whispering.** Measured on a real 33.7 s whisper: window RMS 0.001–0.004 (room ≈ 0.001), Silero max 0.14–0.22; only ~10 s reached whisper, which transcribed it confidently. Keep a window if Silero ≥ 0.1 or RMS ≥ ~2.5× the session's noise floor. Parked after the user reported whispering "way better".
- **Parakeet** as a second engine — faster, far less loop-prone; the custom dictionary won't apply; ~25 European languages.
- **Beam search** behind a hidden default, A/B'd on debug-mode recordings.
- **Transcribe an audio file** (menu item; needs the user-selected-file entitlement).
- **Meeting audio** via ScreenCaptureKit (Screen Recording permission) — a product-direction change.
- **Model lifecycle:** delete or redownload from the menu, show path and checksum.
- **Chunk tuning** (was D7) on debug recordings: 0.8 s pause cuts can split mid-sentence; the seam casing fix runs only on overlapped seams and can lower-case a name that starts the next chunk.
- **CI / local validation** — `scripts/check.sh` exists; wiring it into CI is the next step.

## Manual checks

Worth re-running after audio or session changes, in the dev build:

1. Bluetooth headphones as input, music playing, idle → stays high quality; recording drops to headset mode; after stop it returns within a second or two. Opening the menu doesn't drop it.
2. Short (< 10 s) and long (2–5 min, with pauses) dictation; continuous speech > 30 s (check the forced-cut seam).
3. Cancel (⌘⎋) during recording and during "Transcribing…" → the next recording still pastes.
4. Device switch mid-recording (plug/unplug, AirPods in/out), and Settings' device picker mid-recording.
5. Push-to-record quick tap; stop right after a pause; stop and send (⇧⌘;).
6. Sleep / lock mid-recording → transcript copied, not pasted.
7. "Transcribe while recording" off → single-pass path works.
8. Quiet while recording: several devices ticked; untick one mid-recording; Mac volume lowered and restored.

## Rejected

Don't re-add unless the user explicitly revisits them.

**Product (May 2026):** first-run readiness panel; overlay recording time / auto-stop countdown; per-app profiles (language, snippets, auto-paste, clipboard, model); model recommendation by hardware; snippet tester and JSON import/export; dictionary grouping; user-facing no-speech tuning; manual trust state for copied `.bin` files; "paste target safety" mode; local diagnostics export.

**Recording and models (May 2026):** snapshotting the configuration at start, or locking the model while non-idle — the user wants to change the model mid-recording.

**Out of scope (AGENTS.md):** cloud transcription, telemetry, accounts, sync; persistent transcription history UI (the memory-only recent transcripts are the compromise); LLM rewriting of transcripts (Claude Code etc. already see project context); live streaming captions; app automation via Apple Events (exception: Quiet while recording); salting `initial_prompt` against hallucinations.

**Nov 2026:**
- **Reduced encoder window (`audio_ctx`)** for short chunks — some runs ~2× faster, others returned empty and set off 6–12 s temperature retries. Implementation (`AudioContextSizer`) is in git history.
- **Pinning one language per session** — made whisper translate the other language. Auto stays unforced.
- **Earlier pause cuts** (cut at pauses from ~4–5 s when idle) — declined; L1 is the better route.
- **Auto-Enter per app / detecting Claude Code in a terminal** — the sandbox can't read other apps' window titles (measured `-25204`); covered by stop and send (⇧⌘;). A spoken "send it" trigger is covered the same way.
- **Pausing media** via the play/pause key or MediaRemote — a toggle with no playback state (MediaRemote is closed to third parties since macOS 15.4). Lowering the Mac's volume is used instead; the voice-processing ducking alternative was dropped (it alters the mic signal).
- **Remapping the 🎤 / F5 key** with `hidutil` — not needed.
- **Shift-only cancel shortcuts** (⇧⎋, ⇧;) — a Carbon hotkey can't be Shift-only and a global key monitor doesn't see other apps' keys in the sandbox.
- **"Check for Updates" from GitHub** — not for now.
- **Bundling a local "fix typos" model** — slow on older Macs, and the target (Claude Code) already resolves slips from project context.

## Decisions

| # | Decision | Status |
|---|---|---|
| D1 | Dev and prod side by side via a separate bundle (`com.spokium.mac.dev`, `Spokium Dev.app`), not a VM | done |
| D2 | whisper.cpp 1.8.4 → 1.9.5 | done (no measurable speed change; token-timestamp API and short-audio fixes used) |
| D3 | Live chunked transcription | done, default on |
| D4 | Parakeet later; the dictionary won't apply | idea |
| D5 | Audio retention for retry | idea (see Ideas) |
| D6 | Dev hotkeys: ⌃ added to production's (⌃⌘;, ⌃⇧⌘;) | done |
| D7 | Chunking: cut at ≥ 0.8 s pause once ≥ 10 s, else longest short gap near 28 s, else forced cut with 2 s overlap | done; tune on recordings |
| — | Silero VAD bundled (0.9 MB) instead of downloaded; decides cuts, while keep/drop also counts audible RMS (whispering) | done |
| — | Language: "auto" always unforced; out-of-list detections re-run forced to the session's dominant language | done |
| — | Project file generated by XcodeGen from `Spokium/project.yml` | done |

## Done

**1.5.4 (unreleased at the time of writing):** cancel shortcut back to a session-only Carbon hotkey with the standard recorder (default ⌘⎋; saved Shift-only ones reset); per-model "Use" checkbox for the Neural Engine encoder; private clipboard (current-host-only + transient/concealed markers, toggle in Output); recordings stop on sleep / screen lock (copied, not pasted); model unloaded after 15 idle minutes; dictionary token budget shows ~174 in live mode; auto-stop limit counts per recording; device names, UIDs, quiet-device names and error texts private in logs; Hugging Face downloads pinned to a commit; quiet devices multi-select; single "Lower the Mac's volume" toggle; release script refuses dirty trees, keeps dSYMs, commits and tags.

**1.5.3:** lower or mute the Mac's volume while recording; update flow quits the running app only when idle and relaunches it.

**1.5.2:** code-review fixes — stop-tail race, early push-to-record release, Settings device picker mid-recording, whispered speech chopped into paragraphs, model SHA-1 off the main thread, stop during a device switch, continued session losing its first part, temp-file collisions, CFString leak, readable errors, level timer during menu tracking, Quit can't hang. Neural Engine: dictation never waits for a Core ML load (GPU twin), encoders that don't load within 10 min are marked unusable (M1 Pro + large-v3). Stock-phrase and filler-only hallucinations dropped on near-silence; persistent repeats collapsed; dead-mic chime only for a mic that never produced audio; speed stats ignore outliers and model-load time. Shortcuts ⌘; / ⇧⌘; stop and send. XcodeGen migration; tests in Swift 6; `Spokium Dev.app`; display name fix (1.5.0–1.5.2 showed "Spokium Dev"); README rewrite.

**1.5.0–1.5.1:** Silero VAD chunking; Core ML (Neural Engine) encoder downloads; 20 s clipboard restore in every mode; Settings reorganised (600×500, Output and Integrations tabs, + / − lists); single language menu (Any / one / several) with usage stats; input device re-pointing on removal; cached device list (menu no longer drops Bluetooth headphones into call mode); flat-output (no punctuation) retry; "new line" / "new paragraph"; Quiet while recording (POST/DELETE to local devices); `scripts/check.sh`.

**1.4.x and earlier:** live chunked transcription; Bluetooth HFP fix (engine released on stop); coreaudiod hang fix (engine work off the main thread with timeouts); stop tail; Shift+Esc cancel; Settings-window opening fix; dev bundle; bugs B1–B8 from the first review (queue counter, tap format crash, task leak, transcriber swap, abort race); and the May 2026 phases (menu-bar shell, hotkey and capture, whisper.cpp, model picker, paste pipeline, dictionary/snippets/paragraphs, HUD and polish, release pipeline).
