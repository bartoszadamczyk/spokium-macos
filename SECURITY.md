# Security

Spokium is a local-only dictation tool. This document describes what the app can and cannot do, what protects you from a compromise of Spokium or its dependencies, and the rationale for each privileged capability.

## Threat model

The user's machine is the trust boundary. Spokium is designed so that:

- App Sandbox limits file access mostly to Spokium's container and system locations allowed by macOS sandbox policy.
- App Sandbox prevents inbound server behavior because no server entitlement is granted.
- No transcription content ever leaves the device. There is no telemetry, no analytics, no error reporting service.

Spokium is **not** designed to defend against a malicious operator with physical access — the app necessarily holds the microphone, the global hotkey, and (optionally) the Accessibility permission. A compromised macOS user account compromises Spokium.

## Distribution and signing

- Signed with a **Developer ID Application** certificate.
- **Notarized** by Apple — every release is submitted to `notarytool` and stapled before publication.
- **Hardened Runtime** is enabled. No `allow-jit`, no `allow-unsigned-executable-memory`, no `disable-library-validation`, no `disable-executable-page-protection`, no DYLD env var allowances, no debugger entitlement.
- Distributed via GitHub Releases as a signed `.zip`. **Not distributed via the Mac App Store** — see below.

## App Sandbox

Spokium runs under macOS App Sandbox. The project currently relies on Xcode-generated entitlements from the target's Signing & Capabilities build settings; there is no checked-in `Spokium.entitlements` file. The audited entitlement set is:

| Entitlement | Purpose |
|---|---|
| `com.apple.security.app-sandbox` | Enable App Sandbox confinement |
| `com.apple.security.device.audio-input` | Record audio from the system microphone |
| `com.apple.security.network.client` | Outbound client networking — used in code only to download whisper models from Hugging Face over HTTPS |

What sandbox enforces in practice:

- **Filesystem** — Spokium resolves model storage through `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`, which lands inside the app container for sandboxed builds. It does not request broad user-selected-file entitlements.
- **Network** — outbound client networking is entitled, but source review shows only `URLSession` model downloads from `https://huggingface.co/ggerganov/whisper.cpp/...`. The app has no inbound server entitlement.
- **IPC** — no arbitrary Mach lookups. No whitelisted out-of-process services.
- **Hardware** — only the microphone is unlocked. Camera, Bluetooth, USB, location, contacts, calendars, photo library, and printing are all denied at the entitlement level.

## Permissions

This section is exhaustive: every prompt Spokium can trigger, every entry it can create in System Settings → Privacy & Security, and every entitlement it ships with.

### Required (prompted at first use)

| Permission | Mechanism | Why Spokium needs it | Failure mode |
|---|---|---|---|
| **Microphone** | `NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input` entitlement. macOS shows the standard mic prompt the first time recording starts. Appears under Privacy & Security → Microphone. | Capturing audio via `AVAudioEngine` for transcription. The only sensor Spokium uses. | A modal alert is shown and recording aborts. No fallback — without the mic there is nothing to transcribe. |
| **Accessibility** | `AXIsProcessTrustedWithOptions`. User grants in Privacy & Security → Accessibility. | Synthesizing ⌘V via `CGEvent` so the transcript pastes into the focused window. **Not used for any other purpose** — Spokium does not read other apps' UI, does not monitor keystrokes, does not observe other apps' state. | Spokium preflights `AXIsProcessTrusted` before each paste. If missing, the transcript is left on the clipboard so the user can ⌘V manually; an alert, a persistent menu row, and a "Turn Off Auto-paste" remediation are offered. **Spokium never silently drops the transcript.** Auto-paste can be disabled entirely, in which case Accessibility is never requested. |

### Optional / user-toggled

| Setting | Mechanism | Notes |
|---|---|---|
| **Launch at login** | `SMAppService.mainApp.register()` (Service Management framework). Appears in System Settings → General → Login Items. | Off by default. Toggled in Spokium Settings → General. No separate prompt; the toggle directly registers/unregisters Spokium as a login item. |

### Permissions Spokium explicitly does *not* request

This list is documented because absence is sometimes more important than presence. If you see a prompt that is not on the *Required* table above, something is wrong.

- **Apple Events / Automation** — `AUTOMATION_APPLE_EVENTS = NO` is set in the project's build settings. Spokium cannot script Music, Spotify, the Finder, or any other application via AppleScript / `NSAppleEventDescriptor`. It will never appear in Privacy & Security → Automation.
- **Input Monitoring** — Spokium uses Carbon's `RegisterEventHotKey` (via the `KeyboardShortcuts` package) for its global hotkey. This API does not require Input Monitoring and does not see keystrokes outside the registered hotkey. Spokium will never appear in Privacy & Security → Input Monitoring.
- **Screen Recording** — never requested. No use of `CGWindowList`, `CGDisplayStream`, or `ScreenCaptureKit`.
- **Full Disk Access** — never requested. Sandbox confines app-controlled reads/writes to the app's container and normal system locations allowed by sandbox policy.
- **Camera, Bluetooth, Contacts, Calendars, Reminders, Photos, Location, USB, Printing** — denied at the entitlement level (each `ENABLE_RESOURCE_ACCESS_*` build setting is `NO`). Spokium cannot prompt for these, even by accident.
- **Notifications** — Spokium does not call `UNUserNotificationCenter`. No notification permission prompt. Feedback is delivered via the overlay HUD and the menu bar.
- **Network Server** — `com.apple.security.network.server` is not granted. Spokium cannot accept inbound connections.
- **Network Client** — `com.apple.security.network.client` IS granted, but only outbound HTTPS to `huggingface.co` is used in practice by the current code (Whisper model downloads). No telemetry, no analytics, no crash reporting.
- **Keychain access** — never requested. No items written to or read from the keychain.
- **`get-task-allow` debugging entitlement** — present in Debug builds (Xcode adds it for `lldb` attach). **Not present in Release / notarized builds.**

## Private frameworks

Spokium does **not** link or `dlopen` any private framework. Everything used is public API.

## Data handling

- **Audio** — recorded to a `.caf` file in the sandbox tmp directory, transcribed locally, and deleted on normal success, cancel, start failure, audio-configuration failure, and transcription-task completion paths. `AppDelegate.cleanStaleTempFiles()` removes old `whisper-*.caf` temp files on next launch. Quit while actively recording or transcribing is a known cleanup-hardening area in `APP_REVIEW_IDEAS.md`. **Exception:** when the hidden debug mode (`defaults write com.spokium.mac debugMode -bool true`) is enabled, audio files are moved to `~/Library/Containers/com.spokium.mac/Data/Library/Application Support/Spokium/debug-recordings/` and a markdown sidecar (`{basename}.md`) containing per-segment whisper output (text + `no_speech_prob` + timestamps) is written next to each audio file. The folder is size-capped at 100 MB and wiped immediately when the flag is disabled (via `UserDefaults.didChangeNotification` observer) and on every app launch when the flag is off. No UI surface; opt-in via terminal only. **Debug data never leaves this folder** — no system-wide logging.
- **Transcripts** — placed on `NSPasteboard.general` (and optionally pasted). **Never written to disk.** The optional clipboard-restore feature saves and restores prior clipboard contents in memory only; that buffer is dropped at the end of `Paster.paste`.
- **Logs** — `OSLog` only. Whisper inference results are logged as `model name`, `detected language`, character count, and timing — **never the transcript content**. Grep `Logger(... category:` in the source to verify. This rule holds even with debug mode enabled — debug data is written to a sidecar markdown file in the sandbox debug folder, not to OSLog.
- **No telemetry** — Spokium makes no outbound HTTP request other than:
  - Whisper model downloads from `huggingface.co/ggerganov/whisper.cpp` (initiated by explicit user click).
  - Validated by GGML magic bytes and SHA-1 checksum before being accepted.

## Why not the Mac App Store?

Some features the app already uses would be rejected or banned by App Store review:

- **`CGEvent` keystroke synthesis into other apps' windows** for paste is permitted in principle but routinely rejected for dictation/automation apps in practice. Comparable apps (MacWhisper, Aiko, Superwhisper) are all Developer ID-only for the same reason.
- **Embedded `whisper.xcframework`** — a third-party framework embedded in the app target; introduces review friction under the "no binaries within binaries" guideline.

Given that App Store distribution is not the goal, **App Sandbox in Spokium is pure defense in depth, not a store gatekeeper.** No temporary-exception entitlements are used — every entitlement is one of the standard public capabilities.

## Supply chain

- **`whisper.xcframework`** — `Spokium/Frameworks/whisper.xcframework` is present and tracked in this checkout, and should be treated as a rebuildable artifact from upstream `ggml-org/whisper.cpp`. The upstream commit used to build the current checked-in framework is not recorded in source; record it or untrack the framework before tightening release provenance.
- **`KeyboardShortcuts`** — SPM dependency, pinned via `Package.resolved`. Source: `sindresorhus/KeyboardShortcuts`.
- **Whisper models** — downloaded on demand from `huggingface.co/ggerganov/whisper.cpp`. Each model is validated post-download with:
  - HTTP 2xx status
  - GGML magic bytes at the start of the file
  - SHA-1 checksum match against a hardcoded table

## Reporting a vulnerability

Email security reports to the maintainer listed in the repo's `git log`. Please do not open public issues for security-sensitive reports.
