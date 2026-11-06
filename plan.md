# Spokium — review & roadmap (Nov 2026)

## Decisions

| # | Decision | Status |
|---|---|---|
| D1 | Dev/prod side-by-side: **separate dev bundle ID** (`com.spokium.mac.dev`, "Spokium Dev") instead of a VM | ✅ Decided |
| D2 | Upgrade whisper.cpp xcframework 1.8.4 → **1.9.5** | ✅ Decided |
| D3 | Build **live chunked transcription** (transcribe while recording) | ✅ Decided |
| D4 | Parakeet as an optional second engine — **experiment later**, note that the custom dictionary won't apply to it | ✅ Decided (later) |
| D5 | Audio retention for retry after failure: (a) keep on disk until paste succeeds + crash recovery on next launch, (b) keep only for the current app run, (c) opt-in setting | ❓ **Open** — implementing (b) as the default for now, as it's the most privacy-conservative option that still allows retry |
| D6 | Dev build default hotkey (must differ from prod's ⌥Space or the two apps fight over it) | ❓ Open — proposing ⌃⌥Space |
| D7 | Chunk target length (VAD cut window) | ❓ Open — starting at 10–25 s speech, forced cut at 28 s with 2 s overlap; tune on real recordings |

## Current pipeline (as reviewed)

- `AudioRecorder` writes one native-rate CAF per segment (new segment only on device change).
- On stop, `TranscriptionQueue.run` loads every segment fully into memory, resamples to 16 kHz, concatenates, and makes **one** `whisper_full` call.
- Problems:
  1. **Latency** — nothing is transcribed until stop. 10 min of audio = full 10 min inference after release.
  2. **Long-recording drift / loops** — inside one `whisper_full` call whisper.cpp conditions each 30 s window on the previous window's text, so one bad window propagates. `LoopDetector` only catches ≥5 identical *segments*, not repeated words inside a segment; on detection it re-runs the *whole* recording (2× wait).
  3. **Failure = audio lost** — `run`'s `defer` deletes the audio regardless of outcome (outside debug mode).

## Bugs found

| # | Bug | Severity | Status |
|---|---|---|---|
| B1 | Esc during "Transcribing…": `cancelAll()` zeroes `pendingCount`, then the in-flight task's `defer` decrements → **−1**. Next session's count never reaches 0 → `onIdle` never fires → text never pasted, HUD stuck on "Transcribing…" until Esc again. | High | ✅ Fixed (generation counter in `TranscriptionQueue`) |
| B2 | `installTap` raises an uncatchable ObjC exception if the input format has 0 Hz / 0 channels or mismatches the node's output format. Hit exactly in the device-wake retry loop (Continuity Mic, AirPods). Prime suspect for the intermittent crashes. | High | ✅ Fixed (tap uses `outputFormat`, guards 0 Hz/0 ch, throws `deviceNotReady` so the retry loop handles it) |
| B3 | **Bluetooth headphones stay in low-quality (HFP) mode while idle.** `AudioRecorder` keeps its `AVAudioEngine` alive after stop; once `inputNode` has been touched the engine's I/O unit stays configured with the mic as input, which holds the BT headset in headset profile. Zoom releases its engine when not listening. Fix: create the engine on start, release it on stop, and never touch `inputNode` while idle. | High (UX) | ✅ Fixed in code (engine is optional, created in `start`, released in `stop`) — **needs testing with real BT headphones** |
| B4 | `activeTasks.removeAll { $0.isCancelled }` never removes *finished* tasks → array grows forever. | Low | ✅ Fixed (tasks keyed by UUID, removed on completion) |
| B5 | `tokenCount(for:)` (Dictionary tab) can replace `queue.transcriber` while a transcription runs on the old instance → Esc/quit abort the wrong instance; old whisper context freed whenever the task ends (possible quit crash). | Medium | ✅ Fixed (throwaway transcriber while a run is in flight) |
| B6 | Abort flag reset at the start of `runWhisper` can swallow an Esc that arrived between audio load and inference. | Low | ✅ Fixed (abort epoch token instead of Bool reset) |
| B8 | **Production 1.4.0 hung ("not responding") after toggling recording several times quickly.** Main thread blocked forever in `AVAudioEngine.inputNode` → `AVAudioIOUnit::GetHWFormat`, polling coreaudiod (68% CPU until Spokium was killed). Fix: all engine work on a serial background queue with start/stop timeouts; late-finishing starts are torn down; 250 ms toggle debounce. | High | ✅ Fixed in code — **needs rapid-toggle test in dev, then a 1.4.1 release** |
| B7 | **Settings window doesn't open.** `settingsScene` (`NSHostingSceneRepresentation`) was never registered with `NSApp.addSceneRepresentation`, so `openSettings()` was a no-op. Its root also looked up the controller via `NSApp.delegate as? AppDelegate`, which is SwiftUI's proxy under `@NSApplicationDelegateAdaptor`. (The "task name port right for pid 610" log line is unrelated WindowServer/sandbox noise.) | High | ✅ Fixed — **needs a click-test** |

## whisper.cpp 1.8.4 → 1.9.5 — what we gain

| Release | Change | Why it matters here |
|---|---|---|
| 1.9.0 | NVIDIA Parakeet support | Optional second engine (D4). |
| 1.9.2 | VAD speech segments exposed; token timestamps mapped back to original audio time when VAD is on | Building blocks for live chunking + overlap merge. |
| 1.9.3 | Heap OOB in `log_mel_spectrogram` on very short audio fixed | Live chunking will feed short chunks. |
| 1.9.4 | Decoder re-seeded between calls; Metal leak / flash-attn fixes | Many `whisper_full` calls per session; may help quit-time crashes. |
| 1.9.5 | ggml maintenance | — |

Rebuild: `whisper.cpp/build-xcframework.sh` at tag `v1.9.5`, built outside the repo (`~/Codeplace/whisper-build/`), output copied into `Spokium/Frameworks/whisper.xcframework`.

## Live chunked transcription — design

1. **Capture**: tap → convert each buffer to 16 kHz mono Float32 in the tap (AVAudioConverter) → append to a thread-safe sample buffer (and to the segment file on disk for retry).
2. **Chunking**: prefer cutting at pauses (RMS-based for now; Silero VAD via whisper.cpp as a follow-up, which needs a VAD model download). Once a chunk has ≥ min length, cut at the next pause. If no pause arrives by the max length, force a cut and carry **2 s of overlap** into the next chunk.
3. **Transcription**: each chunk is one `whisper_full` call (≤ 30 s, a single window) on the serial queue *while recording continues*. `initial_prompt` = dictionary + tail (~200 chars) of the previous chunk's text, for casing/punctuation/name continuity without unbounded conditioning.
4. **Overlap merge** (forced cuts only): with token timestamps, drop words in chunk B whose start falls inside the overlap already covered by chunk A. Fix casing at the seam.
5. **Loops**: contained per chunk; retry only that chunk at higher temperature. Extend `LoopDetector` with in-segment repeated-word detection.
6. **Paragraphs**: pause-based cuts that exceed the silence threshold become paragraph breaks.
7. **On stop**: only the last chunk is left to transcribe → near-instant paste.
8. **Failure**: completed chunk texts are kept; failed chunks are retryable from retained audio (D5).

Benefits: low latency, bounded memory, no runaway context, partial results survive failure, and segmented capture also makes mid-recording device changes clean.

## Dev environment (D1)

- Debug configuration: bundle ID `com.spokium.mac.dev`, display name "Spokium Dev". Separate sandbox container, defaults, models dir, and TCC permissions from production.
- Production is installed from a notarized Release build.
- Debug-mode toggle for the dev build: `defaults write com.spokium.mac.dev debugMode -bool true`.
- Default hotkey differs in DEBUG (D6).
- A VM (UTM/Tart) stays useful only for clean-install testing. Metal and mic passthrough in guests are weak, so it isn't the daily dev environment.

## Parakeet (D4, later)

- Faster transducer model; doesn't autoregress on its own text, so it's far less prone to repetition loops.
- **Custom dictionary will not work** (no `initial_prompt` equivalent). Snippets still work.
- Fewer languages (v3 ≈ 25 European languages); confirm coverage before relying on it.
- Needs a model-type field in `WhisperModel`, new HF download entries with SHA-1s, and a second path in `Transcriber`.

## Progress log

**2026-11-05 session** (uncommitted, on `main`):
- B1–B6 fixed.
- Dev bundle: Debug config → `com.spokium.mac.dev` / "Spokium Dev"; DEBUG default hotkey ⌃⌥Space. Verified in the built Info.plist.
- whisper.xcframework rebuilt from tag v1.9.5 (all platform slices, like before). `whisper.h` changes are additive only. Build + all tests pass. Build dir: `~/Codeplace/whisper-build/whisper.cpp`.
- Live chunked transcription implemented: `LiveChunker`, `LiveTranscriptAssembler`, `LiveSampleSink`/`LiveResampler` in `AudioRecorder`, `RecordingController+Live`, `.samples` source in `TranscriptionQueue`, setting `liveTranscription` (default **on**, toggle in Settings → Transcription: "Transcribe while recording").
- `LoopDetector.hasRepeatedPhrase` (in-segment word/phrase loops) triggers the temperature-0.4 retry. If it persists, the retry's text is kept rather than dropped.
- Tests: 98 → 118, all passing. Pure-logic tests for chunker cut rules, seam assembly, and phrase loops.
- AGENTS.md updated.
- **Not verified yet:** real whisper inference on the 1.9.5 framework, since no test exercises it. Live mode end-to-end with a real mic. The Bluetooth fix on real headphones.

## Manual test checklist (dev build)

1. [ ] Run "Spokium Dev" from Xcode. Grant mic + Accessibility to the dev app (separate TCC entry). Download a model in the dev app (separate container).
2. [ ] **Bluetooth (B3):** BT headphones as input, music playing, app idle → stays high quality. Record → drops to headset mode (expected) → after stop it returns to high quality within a second or two.
3. [ ] **Short dictation** (< 10 s): pastes as before.
4. [ ] **Long dictation** (2–5 min with natural pauses): Console shows `Live chunk queued` lines while recording; paste arrives ~1–2 s after stop.
5. [ ] **Continuous speech** > 30 s without pausing (read aloud fast): check the forced-cut seam for duplicated or missing words.
6. [ ] **Paragraphs:** pause ≥ 3 s mid-dictation → paragraph break.
7. [ ] **Esc** during recording, and during "Transcribing…" → next recording still pastes (B1).
8. [ ] **Device switch mid-recording** (AirPods in/out) → no crash, text continues (B2).
9. [ ] Toggle "Transcribe while recording" off → old single-pass path still works.
10. [ ] Debug mode on (`defaults write com.spokium.mac.dev debugMode -bool true`) → long recording → sidecar has segments from all chunks.

## Known limitations / tuning ideas

- Pause cuts at 0.8 s can still split mid-sentence; whisper then capitalises the next chunk / adds a period to the previous one. The casing fix currently runs only on overlapped seams. If this shows up, raise `pauseToCutSeconds` or apply the fix to short-pause seams too.
- The overlap seam casing fix lower-cases capitalised names that genuinely start the next chunk ("Bartek" → "bartek") when the previous chunk didn't end a sentence. Rare (forced cuts only).
- Silence detection is RMS at 0.01, the same as `SilenceDetector`. Noisy rooms may never "pause" → more forced cuts. Silero VAD (next steps) would fix that.
- `deviceNotReady` on the *initial* start surfaces as a generic recording-failed alert; only mid-recording resumes retry.

## Language handling (decided 2026-11-05)

- Pinning one language per session was tried and reverted: it made whisper translate the other language.
- Current: "auto" unforced always. Only when auto lands outside "Languages I speak" is the chunk re-run, forced to the session's dominant language (or the most probable listed language on the first chunk).
- Follow-up idea: on an out-of-list detection, re-transcribe with **more context**, e.g. merge the chunk with its neighbour (or prepend the previous chunk's audio) and de-duplicate via word timestamps, before falling back to forcing a language.

## Next steps

1. [ ] Run the manual test checklist above
2. [ ] Decide D5, then implement retry / recovery UI (keep chunk audio or samples of failed chunks; "Retry last recording" menu item)
3. [ ] Tune D7 chunk parameters on real recordings (debug mode sidecars help)
4. [ ] Silero VAD for chunk cuts (needs a VAD model download + SHA-1)
5. [ ] Parakeet experiment (dictionary won't apply)
6. [ ] Commit in logical pieces: bug fixes / dev bundle / framework bump / live transcription
