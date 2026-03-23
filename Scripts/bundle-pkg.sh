#!/bin/bash
# Build a Mac App Store signed .pkg for VoiceClutch.
# Usage: ./bundle-pkg.sh [--output <path>] [--entitlements <path>] [--provisioning-profile <path>] [--app-sign-identity "<3rd Party Mac Developer Application: Team (TEAMID)>"] [--installer-sign-identity "<3rd Party Mac Developer Installer: Team (TEAMID)>"]

set -euo pipefail

# Load local environment overrides.
if [ -f ".env" ]; then
    set -a
    # shellcheck disable=SC1091
    source ".env"
    set +a
fi

APP_NAME="VoiceClutch"
APP_PATH="${APP_NAME}.app"
OUTPUT_PATH="${APP_NAME}.pkg"
ENTITLEMENTS_PATH="${VOICECLUTCH_MAS_ENTITLEMENTS:-Resources/VoiceClutch.mas.entitlements}"
PROVISIONING_PROFILE="${VOICECLUTCH_MAS_PROVISIONING_PROFILE:-}"
APP_SIGN_IDENTITY="${VOICECLUTCH_MAS_APP_SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${VOICECLUTCH_MAS_INSTALLER_SIGN_IDENTITY:-}"

usage() {
    cat <<'USAGE'
Usage: ./bundle-pkg.sh [options]

Build a Mac App Store signed installer package (.pkg) by:
1) Building the app bundle in Release mode
2) Embedding provisioning profile
3) Signing app payload for MAS
4) Producing and validating signed installer package

Options:
  --output <path>                    Output .pkg path (default: VoiceClutch.pkg)
  --entitlements <path>              Entitlements plist path (default: Resources/VoiceClutch.mas.entitlements)
  --provisioning-profile <path>      Provisioning profile path (.provisionprofile)
  --app-sign-identity <identity>     3rd Party Mac Developer Application signing identity
  --installer-sign-identity <ident>  3rd Party Mac Developer Installer signing identity
  --help, -h                         Show this help message

Environment variables:
  VOICECLUTCH_MAS_APP_SIGN_IDENTITY
  VOICECLUTCH_MAS_INSTALLER_SIGN_IDENTITY
  VOICECLUTCH_MAS_PROVISIONING_PROFILE
  VOICECLUTCH_MAS_ENTITLEMENTS

Notes:
  If present, ./.env is loaded automatically before parsing arguments.
USAGE
}

fail() {
    echo "Error: $1" >&2
    exit 1
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "Required command not found: ${cmd}"
    fi
}

strip_quarantine_attributes() {
    local target="$1"

    if ! command -v xattr >/dev/null 2>&1; then
        echo "⚠️  Warning: xattr command not found; skipping quarantine cleanup."
        return
    fi

    xattr -r -d com.apple.quarantine "$target" 2>/dev/null || true
}

codesign_with_hints() {
    local target="$1"
    shift

    local output
    if ! output=$(codesign "$@" "$target" 2>&1); then
        if [ -n "$output" ]; then
            echo "$output" >&2
        fi
        fail "codesign failed for ${target}"
    fi

    if [ -n "$output" ]; then
        echo "$output"
    fi
}

sign_nested_code() {
    local app_path="$1"
    local target
    local bundle_path
    local bundle_executable
    local bundle_executable_path
    local count=0

    # Sign nested code payloads before the root app.
    while IFS= read -r target; do
        if [ -z "$target" ] || [ "$target" = "$app_path" ]; then
            continue
        fi

        echo "🔏 Signing nested target: ${target}"
        codesign_with_hints "$target" \
            --force \
            --timestamp=none \
            --sign "$APP_SIGN_IDENTITY"
        count=$((count + 1))
    done < <(
        find "$app_path" -depth \
            \( \
                -type d \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" \) \
                -o -type f \( -name "*.dylib" -o -name "*.so" \) \
            \) \
            -print
    )

    # Sign loadable bundles that have an executable.
    while IFS= read -r bundle_path; do
        if [ -z "$bundle_path" ]; then
            continue
        fi

        bundle_executable=""
        if [ -f "$bundle_path/Contents/Info.plist" ]; then
            bundle_executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$bundle_path/Contents/Info.plist" 2>/dev/null || true)
        fi
        if [ -z "$bundle_executable" ]; then
            continue
        fi

        bundle_executable_path="$bundle_path/Contents/MacOS/$bundle_executable"
        if [ ! -f "$bundle_executable_path" ]; then
            continue
        fi

        echo "🔏 Signing loadable bundle: ${bundle_path}"
        codesign_with_hints "$bundle_path" \
            --force \
            --timestamp=none \
            --sign "$APP_SIGN_IDENTITY"
        count=$((count + 1))
    done < <(find "$app_path" -depth -type d -name "*.bundle" -print)

    echo "✅ Signed ${count} nested code target(s)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            if [ -z "${2:-}" ]; then
                fail "--output requires a value"
            fi
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --output=*)
            OUTPUT_PATH="${1#*=}"
            shift
            ;;
        --entitlements)
            if [ -z "${2:-}" ]; then
                fail "--entitlements requires a value"
            fi
            ENTITLEMENTS_PATH="$2"
            shift 2
            ;;
        --entitlements=*)
            ENTITLEMENTS_PATH="${1#*=}"
            shift
            ;;
        --provisioning-profile)
            if [ -z "${2:-}" ]; then
                fail "--provisioning-profile requires a value"
            fi
            PROVISIONING_PROFILE="$2"
            shift 2
            ;;
        --provisioning-profile=*)
            PROVISIONING_PROFILE="${1#*=}"
            shift
            ;;
        --app-sign-identity)
            if [ -z "${2:-}" ]; then
                fail "--app-sign-identity requires a value"
            fi
            APP_SIGN_IDENTITY="$2"
            shift 2
            ;;
        --app-sign-identity=*)
            APP_SIGN_IDENTITY="${1#*=}"
            shift
            ;;
        --installer-sign-identity)
            if [ -z "${2:-}" ]; then
                fail "--installer-sign-identity requires a value"
            fi
            INSTALLER_SIGN_IDENTITY="$2"
            shift 2
            ;;
        --installer-sign-identity=*)
            INSTALLER_SIGN_IDENTITY="${1#*=}"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

require_command codesign
require_command productbuild
require_command pkgutil
require_command spctl
require_command swift
require_command xcodebuild
require_command xattr

if [ -z "$PROVISIONING_PROFILE" ]; then
    fail "Missing provisioning profile. Pass --provisioning-profile or set VOICECLUTCH_MAS_PROVISIONING_PROFILE."
fi
if [ -z "$APP_SIGN_IDENTITY" ]; then
    fail "Missing app signing identity. Pass --app-sign-identity or set VOICECLUTCH_MAS_APP_SIGN_IDENTITY."
fi
if [ -z "$INSTALLER_SIGN_IDENTITY" ]; then
    fail "Missing installer signing identity. Pass --installer-sign-identity or set VOICECLUTCH_MAS_INSTALLER_SIGN_IDENTITY."
fi
if [ ! -f "$PROVISIONING_PROFILE" ]; then
    fail "Provisioning profile not found: ${PROVISIONING_PROFILE}"
fi
if [ ! -f "$ENTITLEMENTS_PATH" ]; then
    fail "Entitlements file not found: ${ENTITLEMENTS_PATH}"
fi
if [ ! -f "./Scripts/build.sh" ]; then
    fail "Required build script not found: ./Scripts/build.sh"
fi

echo "🔨 Building VoiceClutch production app bundle (without Developer ID certification)..."
bash "./Scripts/build.sh" --production --skip-certification

if [ ! -d "$APP_PATH" ]; then
    fail "Expected app bundle not found after build: ${APP_PATH}"
fi

# Ensure payload does not retain quarantine metadata before signing and packaging.
echo "🧹 Clearing quarantine metadata from app bundle..."
strip_quarantine_attributes "$APP_PATH"

echo "📄 Embedding provisioning profile..."
cp "$PROVISIONING_PROFILE" "${APP_PATH}/Contents/embedded.provisionprofile"
strip_quarantine_attributes "${APP_PATH}/Contents/embedded.provisionprofile"

echo "🔐 Signing app payload for Mac App Store..."
sign_nested_code "$APP_PATH"

echo "🔏 Signing root app bundle..."
codesign_with_hints "$APP_PATH" \
    --deep \
    --force \
    --timestamp=none \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$APP_SIGN_IDENTITY"

echo "🔎 Verifying app code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"

echo "📦 Building signed installer package..."
productbuild \
    --component "$APP_PATH" /Applications \
    --sign "$INSTALLER_SIGN_IDENTITY" \
    "$OUTPUT_PATH"

# Remove quarantine from generated installer package if inherited from environment.
strip_quarantine_attributes "$OUTPUT_PATH"

echo "🧾 Verifying installer package signature..."
pkgutil --check-signature "$OUTPUT_PATH"

echo "🛡️  Assessing installer package with Gatekeeper..."
if ! spctl --assess --type install --verbose=4 "$OUTPUT_PATH"; then
    if echo "$INSTALLER_SIGN_IDENTITY" | grep -Eq "3rd Party Mac Developer Installer|Mac Installer Distribution"; then
        echo "⚠️  Gatekeeper rejected the installer package."
        echo "   This is expected for Mac App Store submission packages; continuing."
    else
        fail "Gatekeeper installer assessment failed."
    fi
fi

OUTPUT_ABS_PATH="$(cd "$(dirname "$OUTPUT_PATH")" && pwd -P)/$(basename "$OUTPUT_PATH")"
echo "✅ MAS installer package created: ${OUTPUT_ABS_PATH}"
