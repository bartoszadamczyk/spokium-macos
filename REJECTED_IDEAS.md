# Rejected Ideas

These ideas were explicitly declined during the May 18, 2026 app-review cleanup. Do not re-add them to `APP_REVIEW_IDEAS.md`, the roadmap, or future planning suggestions unless the user explicitly asks to revisit them.

## Recording And Model Selection

- Snapshot recording configuration at start. The user wants to be able to change the selected model while recording, so model changes during a recording should remain possible.
- Lock model selection while non-idle or make model choice session-scoped. Same rationale: do not disable mid-recording model selection as a product direction.

## Product Ideas

- First-run readiness panel.
- Overlay recording time and auto-stop countdown.
- Per-app profiles for language, snippets, auto-paste, clipboard restore, and model choice.
- Model recommendation based on hardware, memory, or disk.
- Snippet tester and JSON import/export.
- Dictionary grouping by language, app profile, or topic.
- User-facing no-speech tuning controls.
- Manual model trust state for copied `.bin` files.
- Paste target safety mode that leaves text on the clipboard if focus changes.
- Local diagnostics export.

## Reduced whisper encoder window (`audio_ctx`) for short chunks — rejected 2026-11-06

Idea: encode only `chunk length + 1 s` (floor ~7.7 s) instead of whisper's fixed 30 s window, to speed up short live chunks.
Result with large-v3 on M3 Max: some runs were ~2× faster, but others returned empty or 1–4 characters and set off 6–12 s temperature-fallback retries (high GPU load). With the full window the same chunks took ~0.84 s and were correct. Unreliable → removed. The implementation (`AudioContextSizer`, `params.audio_ctx`) is in git history if it's worth retrying with a larger floor or another model.

