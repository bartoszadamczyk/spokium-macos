# Security

Vox is a local-only dictation tool. This document describes what the app can and cannot do, what protects you from a compromise of Vox or its dependencies, and the rationale for each privileged capability.

## Threat model

The user's machine is the trust boundary. Vox is designed so that:

- A bug or supply-chain compromise in Vox or its dependencies (whisper.cpp, `KeyboardShortcuts`, swift runtime) cannot read files outside the app's container.
- A bug cannot exfiltrate data over arbitrary network protocols.
- No transcription content ever leaves the device. There is no telemetry, no analytics, no error reporting service.

Vox is **not** designed to defend against a malicious operator with physical access — the app necessarily holds the microphone, the global hotkey, and (optionally) the Accessibility permission. A compromised macOS user account compromises Vox.

## Distribution and signing

- Signed with a **Developer ID Application** certificate.
- **Notarized** by Apple — every release is submitted to `notarytool` and stapled before publication.
- **Hardened Runtime** is enabled. No `allow-jit`, no `allow-unsigned-executable-memory`, no `disable-library-validation`, no `disable-executable-page-protection`, no DYLD env var allowances, no debugger entitlement.
- Distributed via GitHub Releases as a signed `.zip`. **Not distributed via the Mac App Store** — see below.

## App Sandbox

Vox runs under macOS App Sandbox. The entitlements file (`Vox/Vox.entitlements`) is the complete, audited list:

| Entitlement | Purpose |
|---|---|
| `com.apple.security.app-sandbox` | Enable App Sandbox confinement |
| `com.apple.security.device.audio-input` | Record audio from the system microphone |
| `com.apple.security.network.client` | Outbound HTTPS only — used to download whisper models from Hugging Face |

What sandbox enforces in practice:

- **Filesystem** — Vox can only read/write its container at `~/Library/Containers/com.bartoszadamczyk.Vox/...` plus user-selected paths via the open/save panels. It cannot read your home directory, your keychain, other apps' containers, or system files outside `/System` and `/Library/Frameworks`.
- **Network** — outbound HTTPS only. The app cannot bind a listening socket, cannot make outbound non-TLS connections, and cannot scan your LAN.
- **IPC** — no arbitrary Mach lookups. No whitelisted out-of-process services.
- **Hardware** — only the microphone is unlocked. Camera, Bluetooth, USB, location, contacts, calendars, photo library, and printing are all denied at the entitlement level.

## Permissions

This section is exhaustive: every prompt Vox can trigger, every entry it can create in System Settings → Privacy & Security, and every entitlement it ships with.

### Required (prompted at first use)

| Permission | Mechanism | Why Vox needs it | Failure mode |
|---|---|---|---|
| **Microphone** | `NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input` entitlement. macOS shows the standard mic prompt the first time recording starts. Appears under Privacy & Security → Microphone. | Capturing audio via `AVAudioEngine` for transcription. The only sensor Vox uses. | A modal alert is shown and recording aborts. No fallback — without the mic there is nothing to transcribe. |
| **Accessibility** | `AXIsProcessTrustedWithOptions`. User grants in Privacy & Security → Accessibility. | Synthesizing ⌘V via `CGEvent` so the transcript pastes into the focused window. **Not used for any other purpose** — Vox does not read other apps' UI, does not monitor keystrokes, does not observe other apps' state. | Vox preflights `AXIsProcessTrusted` before each paste. If missing, the transcript is left on the clipboard so the user can ⌘V manually; an alert, a persistent menu row, and a "Turn Off Auto-paste" remediation are offered. **Vox never silently drops the transcript.** Auto-paste can be disabled entirely, in which case Accessibility is never requested. |

### Optional / user-toggled

| Setting | Mechanism | Notes |
|---|---|---|
| **Launch at login** | `SMAppService.mainApp.register()` (Service Management framework). Appears in System Settings → General → Login Items. | Off by default. Toggled in Vox Settings → General. No separate prompt; the toggle directly registers/unregisters Vox as a login item. |

### Permissions Vox explicitly does *not* request

This list is documented because absence is sometimes more important than presence. If you see a prompt that is not on the *Required* table above, something is wrong.

- **Apple Events / Automation** — `AUTOMATION_APPLE_EVENTS = NO` is set in the project's build settings. Vox cannot script Music, Spotify, the Finder, or any other application via AppleScript / `NSAppleEventDescriptor`. It will never appear in Privacy & Security → Automation.
- **Input Monitoring** — Vox uses Carbon's `RegisterEventHotKey` (via the `KeyboardShortcuts` package) for its global hotkey. This API does not require Input Monitoring and does not see keystrokes outside the registered hotkey. Vox will never appear in Privacy & Security → Input Monitoring.
- **Screen Recording** — never requested. No use of `CGWindowList`, `CGDisplayStream`, or `ScreenCaptureKit`.
- **Full Disk Access** — never requested. Sandbox confines reads/writes to the app's container plus user-selected paths.
- **Camera, Bluetooth, Contacts, Calendars, Reminders, Photos, Location, USB, Printing** — denied at the entitlement level (each `ENABLE_RESOURCE_ACCESS_*` build setting is `NO`). Vox cannot prompt for these, even by accident.
- **Notifications** — Vox does not call `UNUserNotificationCenter`. No notification permission prompt. Feedback is delivered via the overlay HUD and the menu bar.
- **Network Server** — `com.apple.security.network.server` is not granted. Vox cannot accept inbound connections.
- **Network Client** — `com.apple.security.network.client` IS granted, but only outbound HTTPS to `huggingface.co` is used in practice (Whisper model downloads). No telemetry, no analytics, no crash reporting.
- **Keychain access** — never requested. No items written to or read from the keychain.
- **`get-task-allow` debugging entitlement** — present in Debug builds (Xcode adds it for `lldb` attach). **Not present in Release / notarized builds.**

## Private frameworks

Vox does **not** link or `dlopen` any private framework. Everything used is public API.

## Data handling

- **Audio** — recorded to a `.caf` file in the sandbox tmp directory, transcribed locally, and **deleted on every exit path** (success, cancel, error). Verified via `defer` in `RecordingController.transcribe(url:)`.
- **Transcripts** — placed on `NSPasteboard.general` (and optionally pasted). **Never written to disk.** The optional clipboard-restore feature saves and restores prior clipboard contents in memory only; that buffer is dropped at the end of `Paster.paste`.
- **Logs** — `OSLog` only. Whisper inference results are logged as `model name`, `detected language`, character count, and timing — **never the transcript content**. Grep `Logger(... category:` in the source to verify.
- **No telemetry** — Vox makes no outbound HTTP request other than:
  - Whisper model downloads from `huggingface.co/ggerganov/whisper.cpp` (initiated by explicit user click).
  - Validated by GGML magic bytes and SHA-1 checksum before being accepted.

## Why not the Mac App Store?

Some features the app already uses would be rejected or banned by App Store review:

- **`CGEvent` keystroke synthesis into other apps' windows** for paste is permitted in principle but routinely rejected for dictation/automation apps in practice. Comparable apps (MacWhisper, Aiko, Superwhisper) are all Developer ID-only for the same reason.
- **Bundled `whisper.xcframework`** — a third-party binary not from the App Store; introduces review friction under the "no binaries within binaries" guideline.

Given that App Store distribution is not the goal, **App Sandbox in Vox is pure defense in depth, not a store gatekeeper.** No temporary-exception entitlements are used — every entitlement is one of the standard public capabilities.

## Supply chain

- **`whisper.xcframework`** — built locally from upstream `ggml-org/whisper.cpp` via the upstream `build-xcframework.sh`. Not committed. Each developer builds their own from a pinned commit.
- **`KeyboardShortcuts`** — SPM dependency, pinned via `Package.resolved`. Source: `sindresorhus/KeyboardShortcuts`.
- **Whisper models** — downloaded on demand from `huggingface.co/ggerganov/whisper.cpp`. Each model is validated post-download with:
  - HTTP 200 status
  - GGML magic bytes at the start of the file
  - SHA-1 checksum match against a hardcoded table

## Reporting a vulnerability

Email security reports to the maintainer listed in the repo's `git log`. Please do not open public issues for security-sensitive reports.
