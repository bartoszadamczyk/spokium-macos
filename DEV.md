# Development environment

Spokium is developed by running two separate copies side by side: a stable **production** build you use every day, and a **dev** build you run from Xcode. They have different bundle IDs, so macOS treats them as two unrelated apps.

## Setup

Only the **Debug** build configuration differs. Release is unchanged.

| | Production | Dev |
|---|---|---|
| Built by | Product → Archive (Release), or installed from a GitHub release | ⌘R in Xcode (Debug) |
| Bundle ID | `com.spokium.mac` | `com.spokium.mac.dev` |
| Display name | Spokium | Spokium Dev |
| Default hotkeys | ⌘; record, ⇧⌘; stop and send | ⌃⌘; and ⌃⇧⌘; (`#if DEBUG` in `Hotkey/HotkeyName.swift`) |
| Location | `/Applications/Spokium.app` | Xcode DerivedData, as `Spokium Dev.app` (process `Spokium Dev`) |

## What's separate

Because the bundle IDs differ, each copy has its own:

- **Sandbox container** (`~/Library/Containers/com.spokium.mac.dev/…`). Models, debug recordings and temp audio are separate.
- **Settings.** Dictionary, snippets, language and hotkey in production are untouched by the dev build. The dev build starts with defaults.
- **Permissions.** Microphone and Accessibility are granted per app. "Spokium Dev" appears as its own entry in System Settings → Privacy & Security.
- **Launch at login.** Enable it in production only, so the dev build doesn't start itself at login.

Tests (⌘U) are hosted in the dev app, so they never touch production data either.

## First-time setup

1. **Production:** build a Release archive (Product → Archive → Developer ID → notarize) or install the latest GitHub release into `/Applications`.
2. **Dev:** press ⌘R in Xcode. Grant microphone access when prompted. Accessibility is requested the first time the dev build tries to paste.
3. **Models:** the dev build has none yet. The Model tab lists every *available* model with a Download button in both apps; that doesn't mean they're installed. Either download one in Settings → Model, or skip the download. Open "Show in Finder" in both apps and copy the `.bin` files across. The sandbox accepts files dropped in through Finder.
4. Copy the dictionary and snippets across by hand if you want the same setup.

## Debug mode

The `defaults` domain is the bundle ID of the app you mean:

```sh
defaults write com.spokium.mac.dev debugMode -bool true   # dev
defaults write com.spokium.mac debugMode -bool true       # production
```

Debug recordings for the dev build land in `~/Library/Containers/com.spokium.mac.dev/Data/Library/Application Support/Spokium/debug-recordings/`.

## Things to watch for

- **Telling them apart.** In Debug builds the menu bar icon has a small "DEV" label (`MenuBarIcon`), and the Settings window has an orange "DEV BUILD · com.spokium.mac.dev" strip (`DevBuildBanner` in `SettingsView.swift`).
- **Profiling uses the production identity.** The scheme's Profile action (⌘I, Instruments) builds **Release**, so it runs as `com.spokium.mac` with your real settings and models. Switch Profile to Debug in the scheme, or add a dedicated configuration, if that matters.
- **Granting Accessibility to the dev build.** The dev build may not prompt, and in builds before 1.5.3 both showed up as "Spokium" in the list (the dev one is now `Spokium Dev.app`). What works: System Settings → Privacy & Security → Accessibility → **+** → ⌘⇧G → `~/Library/Developer/Xcode/DerivedData/Spokium-*/Build/Products/Debug/Spokium Dev.app` → enable it. Toggling an existing row may silently revert if that row belongs to a different signature of the same bundle ID (e.g. an Xcode archive of `com.spokium.mac` vs. the Developer ID build in `/Applications`). If it gets confused: `tccutil reset Accessibility com.spokium.mac.dev` and add it again.
- **Accessibility can reset after rebuilds.** TCC remembers the permission by code signature. With the same Apple Development certificate it usually persists. If paste stops working in the dev build, turn "Spokium Dev" off and on again under Accessibility.
- **Hotkeys must differ.** Only one app can register a given Carbon hotkey; the second silently gets nothing. Keep the two shortcuts different if you change either.
- **Both builds record and paste.** Only the app whose hotkey you pressed is listening, so they don't conflict, but make sure you know which one you triggered.

## Project file (XcodeGen)

The Xcode project is generated from `Spokium/project.yml` (`brew install xcodegen`, then `cd Spokium && xcodegen generate`). Change build settings, capabilities, Info.plist keys, packages or schemes there, never in Xcode's UI. Version numbers are in `Spokium/Version.xcconfig`. New Swift files don't need a regenerate — the source folders are synced.

## Pre-release checks

`scripts/check.sh` (≈ 40 s) catches a release that builds but is subtly broken:

| Command | Runs |
|---|---|
| `./scripts/check.sh` | log-privacy grep, all tests, a Release build, then bundle checks on it |
| `./scripts/check.sh --tests` | tests only |
| `./scripts/check.sh path/to/Spokium.app` | bundle checks plus Developer ID, team, stapled ticket and Gatekeeper |

Bundle checks: bundle id `com.spokium.mac`, `LSUIElement`, exactly the three entitlements, hardened runtime, deep signature, embedded `whisper.framework`, bundled Silero model with its SHA-256. `release.sh` runs `--tests` before bumping the version and the app form on the stapled export, and stops before installing if anything fails. Logs go to `build/check-*.log`.

## Rebuilding whisper.xcframework

```sh
mkdir -p ~/Codeplace/whisper-build && cd ~/Codeplace/whisper-build
git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp.git
cd whisper.cpp && ./build-xcframework.sh
# then replace Spokium/Frameworks/whisper.xcframework with build-apple/whisper.xcframework
```

Build outside the repo. Diff `whisper.h` between the old and new framework before swapping, then build and run the tests.

## Why not a VM

A macOS VM (UTM, Tart, Parallels) is still useful for **clean-install testing**: first-run permission prompts, or a Mac with no models. For daily development it's worse. Metal acceleration in macOS guests is limited, so whisper runs much slower, and microphone and Bluetooth passthrough are unreliable. Those are exactly the things this app needs to exercise.

## Reading logs

In zsh, `log` is a shell builtin, so always call the macOS tool by its full path:

```sh
/usr/bin/log show --last 1h --info --predicate 'subsystem == "com.spokium.mac"' \
  | grep -E "Model loaded|stop→paste|Transcribed:|chunk queued|Auto-detected"
```

Add `AND processImagePath CONTAINS "Debug"` to the predicate to see only the dev build.

