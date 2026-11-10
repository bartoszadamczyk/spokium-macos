#!/usr/bin/env bash
# Pre-release sanity checks. Catches a release that builds but is subtly broken.
#
#   ./scripts/check.sh                 tests + Release build + bundle checks on that build
#   ./scripts/check.sh --tests         tests only
#   ./scripts/check.sh path/to/Spokium.app
#                                      bundle checks + distribution checks (Developer ID,
#                                      notarization ticket, Gatekeeper) on an exported app
#
# release.sh runs --tests before archiving and the app form on the stapled export.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/Spokium/Spokium.xcodeproj"
SCHEME="Spokium"
BUNDLE_ID="com.spokium.mac"
TEAM_ID="6J9C6FCCS5"
EXPECTED_ENTITLEMENTS="com.apple.security.app-sandbox com.apple.security.device.audio-input com.apple.security.network.client"
VAD_MODEL="ggml-silero-v6.2.0.bin"
VAD_SHA256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

FAILURES=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

run_tests() {
    section "Tests"
    local log="$REPO_ROOT/build/check-tests.log"
    mkdir -p "$REPO_ROOT/build"
    if xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' >"$log" 2>&1; then
        # No count: xcodebuild's own log lines can land inside a result line, so grepping
        # them undercounts. The exit status is what matters.
        pass "all tests passed"
    else
        fail "tests failed — see build/check-tests.log"
        grep -E "✘|error:|failed" "$log" | head -20
    fi
}

build_release() {
    section "Release build" >&2
    local dd="$REPO_ROOT/build/check-derived"
    local log="$REPO_ROOT/build/check-build.log"
    if xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -derivedDataPath "$dd" >"$log" 2>&1; then
        pass "built" >&2
        echo "$dd/Build/Products/Release/Spokium.app"
    else
        fail "Release build failed — see build/check-build.log" >&2
        grep -E "error:" "$log" | head -20 >&2
        echo ""
    fi
}

check_source() {
    section "Source"
    # Transcript text must never reach OSLog (AGENTS.md hard constraint): flag log calls
    # that interpolate text-like values directly rather than e.g. their .count.
    local hits
    hits=$(grep -rnE 'logger\.[a-z]+\(.*\\\((self\.)?(text|result\.text|transcript|assembled|finalText)[),]' \
        "$REPO_ROOT/Spokium/Spokium" --include='*.swift' || true)
    if [ -z "$hits" ]; then
        pass "no transcript text interpolated into log calls"
    else
        fail "log call may include transcript text:"
        echo "$hits"
    fi
}

check_bundle() {
    local app="$1" distribution="$2"
    section "Bundle: $app"
    if [ ! -d "$app" ]; then fail "app not found"; return; fi
    local plist="$app/Contents/Info.plist"

    local id version build
    id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null)
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null)
    build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null)
    echo "  version $version (build $build)"
    [ "$id" = "$BUNDLE_ID" ] && pass "bundle id $id" || fail "bundle id is '$id', expected $BUNDLE_ID (Debug build?)"

    [ "$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$plist" 2>/dev/null)" = "true" ] \
        && pass "LSUIElement (no Dock icon)" || fail "LSUIElement missing — app would show a Dock icon"

    # Plain http is allowed only to the local network (Quiet while recording).
    if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsArbitraryLoads" "$plist" >/dev/null 2>&1; then
        fail "App Transport Security allows arbitrary loads"
    else
        pass "App Transport Security: local networking only"
    fi

    local ents
    ents=$(codesign -d --entitlements :- "$app" 2>/dev/null | plutil -convert json -o - - 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(k for k,v in d.items() if v is True)))')
    local extra=""
    for e in $ents; do
        case " $EXPECTED_ENTITLEMENTS " in *" $e "*) ;; *)
            # Development signing adds get-task-allow; only a problem for distribution.
            if [ "$e" = "com.apple.security.get-task-allow" ] && [ "$distribution" = "no" ]; then continue; fi
            extra="$extra $e" ;;
        esac
    done
    local missing=""
    for e in $EXPECTED_ENTITLEMENTS; do
        case " $ents " in *" $e "*) ;; *) missing="$missing $e" ;; esac
    done
    [ -z "$missing$extra" ] && pass "entitlements: sandbox, microphone, network client" \
        || fail "entitlements differ — missing:${missing:- none} unexpected:${extra:- none}"

    # Captured first: grep -q exiting early would SIGPIPE codesign and trip pipefail.
    local sig
    sig=$(codesign -dvv "$app" 2>&1)
    grep -q "flags=.*runtime" <<<"$sig" && pass "hardened runtime" || fail "hardened runtime not enabled"
    codesign --verify --deep --strict "$app" 2>/dev/null && pass "signature valid (deep, strict)" || fail "signature invalid"

    [ -d "$app/Contents/Frameworks/whisper.framework" ] && pass "whisper.framework embedded" || fail "whisper.framework not embedded"

    local model="$app/Contents/Resources/$VAD_MODEL"
    if [ -f "$model" ] && [ "$(shasum -a 256 "$model" | cut -d' ' -f1)" = "$VAD_SHA256" ]; then
        pass "Silero VAD model bundled, checksum OK"
    else
        fail "Silero VAD model missing or checksum mismatch"
    fi

    [ "$distribution" = "yes" ] || return
    grep -q "Authority=Developer ID Application" <<<"$sig" \
        && pass "signed with Developer ID" || fail "not signed with Developer ID"
    grep -q "TeamIdentifier=$TEAM_ID" <<<"$sig" \
        && pass "team $TEAM_ID" || fail "unexpected team identifier"
    xcrun stapler validate "$app" >/dev/null 2>&1 && pass "notarization ticket stapled" || fail "no stapled notarization ticket"
    grep -q "source=Notarized Developer ID" <<<"$(spctl -a -vv "$app" 2>&1)" \
        && pass "Gatekeeper: accepted (Notarized Developer ID)" || fail "Gatekeeper rejects the app"
}

case "${1:-}" in
    --tests)
        run_tests
        ;;
    "")
        check_source
        run_tests
        APP=$(build_release)
        # build_release runs in a subshell, so its own failure count is lost.
        if [ -n "$APP" ]; then check_bundle "$APP" no; else FAILURES=$((FAILURES + 1)); fi
        ;;
    *)
        check_source
        check_bundle "$1" yes
        ;;
esac

echo
if [ "$FAILURES" -eq 0 ]; then
    printf '\033[32mAll checks passed.\033[0m\n'
else
    printf '\033[31m%d check(s) failed.\033[0m\n' "$FAILURES"
    exit 1
fi
