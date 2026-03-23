#!/bin/bash
# Upload an existing macOS .pkg build to App Store Connect with JWT auth.
# Usage:
#   ./upload.sh [--file <path>] [--api-key-id <id>] [--api-issuer-id <uuid>] [--api-key-path <path>] [--apple-id <id>] [--bundle-id <id>] [--bundle-short-version <ver>] [--bundle-version <build>] [--no-wait]

set -euo pipefail

# Load local environment overrides.
if [ -f ".env" ]; then
    set -a
    # shellcheck disable=SC1091
    source ".env"
    set +a
fi

PKG_FILE="VoiceClutch.pkg"
API_KEY_ID="${APP_STORE_CONNECT_API_KEY_ID:-}"
API_ISSUER_ID="${APP_STORE_CONNECT_API_KEY_ISSUER_ID:-}"
API_KEY_PATH="${APP_STORE_CONNECT_API_KEY_PATH:-}"
APPLE_ID="${VOICECLUTCH_APPLE_ID:-}"
BUNDLE_ID="${VOICECLUTCH_BUNDLE_ID:-}"
BUNDLE_SHORT_VERSION="${VOICECLUTCH_BUNDLE_SHORT_VERSION:-}"
BUNDLE_VERSION="${VOICECLUTCH_BUNDLE_VERSION:-}"
WAIT_FOR_PROCESSING=true

usage() {
    cat <<'USAGE'
Usage: ./upload.sh [options]

Upload an existing macOS installer package (.pkg) to App Store Connect.
This script does not build or package the app.

Options:
  --file <path>                  Path to .pkg file (default: VoiceClutch.pkg)
  --api-key-id <id>              App Store Connect API Key ID
  --api-issuer-id <uuid>         App Store Connect API Issuer ID
  --api-key-path <path>          Path to AuthKey_<KEY_ID>.p8
  --apple-id <numeric-id>        App Apple ID in App Store Connect
  --bundle-id <id>               App bundle identifier
  --bundle-short-version <ver>   CFBundleShortVersionString (for example: 1.2.3)
  --bundle-version <build>       CFBundleVersion build number (for example: 42)
  --no-wait                      Do not wait for upload to reach processing status
  --help, -h                     Show this help message

Environment variables:
  APP_STORE_CONNECT_API_KEY_ID
  APP_STORE_CONNECT_API_KEY_ISSUER_ID
  APP_STORE_CONNECT_API_KEY_PATH
  VOICECLUTCH_APPLE_ID
  VOICECLUTCH_BUNDLE_ID
  VOICECLUTCH_BUNDLE_SHORT_VERSION
  VOICECLUTCH_BUNDLE_VERSION

Notes:
  If present, ./.env is loaded automatically before parsing arguments.
  CLI flags override environment variables.
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

redact_value() {
    local value="$1"
    local length="${#value}"

    if [ -z "$value" ]; then
        echo "<empty>"
        return
    fi

    if [ "$length" -le 6 ]; then
        echo "***"
        return
    fi

    echo "${value:0:4}...${value: -2}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)
            [ -n "${2:-}" ] || fail "--file requires a value"
            PKG_FILE="$2"
            shift 2
            ;;
        --file=*)
            PKG_FILE="${1#*=}"
            shift
            ;;
        --api-key-id)
            [ -n "${2:-}" ] || fail "--api-key-id requires a value"
            API_KEY_ID="$2"
            shift 2
            ;;
        --api-key-id=*)
            API_KEY_ID="${1#*=}"
            shift
            ;;
        --api-issuer-id)
            [ -n "${2:-}" ] || fail "--api-issuer-id requires a value"
            API_ISSUER_ID="$2"
            shift 2
            ;;
        --api-issuer-id=*)
            API_ISSUER_ID="${1#*=}"
            shift
            ;;
        --api-key-path)
            [ -n "${2:-}" ] || fail "--api-key-path requires a value"
            API_KEY_PATH="$2"
            shift 2
            ;;
        --api-key-path=*)
            API_KEY_PATH="${1#*=}"
            shift
            ;;
        --apple-id)
            [ -n "${2:-}" ] || fail "--apple-id requires a value"
            APPLE_ID="$2"
            shift 2
            ;;
        --apple-id=*)
            APPLE_ID="${1#*=}"
            shift
            ;;
        --bundle-id)
            [ -n "${2:-}" ] || fail "--bundle-id requires a value"
            BUNDLE_ID="$2"
            shift 2
            ;;
        --bundle-id=*)
            BUNDLE_ID="${1#*=}"
            shift
            ;;
        --bundle-short-version)
            [ -n "${2:-}" ] || fail "--bundle-short-version requires a value"
            BUNDLE_SHORT_VERSION="$2"
            shift 2
            ;;
        --bundle-short-version=*)
            BUNDLE_SHORT_VERSION="${1#*=}"
            shift
            ;;
        --bundle-version)
            [ -n "${2:-}" ] || fail "--bundle-version requires a value"
            BUNDLE_VERSION="$2"
            shift 2
            ;;
        --bundle-version=*)
            BUNDLE_VERSION="${1#*=}"
            shift
            ;;
        --no-wait)
            WAIT_FOR_PROCESSING=false
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

require_command xcrun
if ! xcrun --find altool >/dev/null 2>&1; then
    fail "Unable to locate altool via xcrun."
fi

[ -n "$API_KEY_ID" ] || fail "Missing API key ID. Pass --api-key-id or set APP_STORE_CONNECT_API_KEY_ID."
[ -n "$API_ISSUER_ID" ] || fail "Missing API issuer ID. Pass --api-issuer-id or set APP_STORE_CONNECT_API_KEY_ISSUER_ID."
[ -n "$API_KEY_PATH" ] || fail "Missing API key path. Pass --api-key-path or set APP_STORE_CONNECT_API_KEY_PATH."
[ -n "$APPLE_ID" ] || fail "Missing Apple ID. Pass --apple-id or set VOICECLUTCH_APPLE_ID."
[ -n "$BUNDLE_ID" ] || fail "Missing bundle ID. Pass --bundle-id or set VOICECLUTCH_BUNDLE_ID."
[ -n "$BUNDLE_SHORT_VERSION" ] || fail "Missing bundle short version. Pass --bundle-short-version or set VOICECLUTCH_BUNDLE_SHORT_VERSION."
[ -n "$BUNDLE_VERSION" ] || fail "Missing bundle version. Pass --bundle-version or set VOICECLUTCH_BUNDLE_VERSION."

if [[ ! "$PKG_FILE" =~ \.pkg$ ]]; then
    fail "Package file must have a .pkg extension: ${PKG_FILE}"
fi
if [ ! -f "$PKG_FILE" ]; then
    fail "Package file not found: ${PKG_FILE}"
fi
if ! [[ "$APPLE_ID" =~ ^[0-9]+$ ]]; then
    fail "Apple ID must be numeric: ${APPLE_ID}"
fi
if [ ! -f "$API_KEY_PATH" ]; then
    fail "API key file not found: ${API_KEY_PATH}"
fi

API_KEY_BASENAME="$(basename "$API_KEY_PATH")"
EXPECTED_AUTHKEY_NAME="AuthKey_${API_KEY_ID}.p8"
EXPECTED_APIKEY_NAME="ApiKey_${API_KEY_ID}.p8"
if [ "$API_KEY_BASENAME" != "$EXPECTED_AUTHKEY_NAME" ] && [ "$API_KEY_BASENAME" != "$EXPECTED_APIKEY_NAME" ]; then
    fail "API key file name must match key ID. Expected ${EXPECTED_AUTHKEY_NAME} (or ${EXPECTED_APIKEY_NAME}), got ${API_KEY_BASENAME}."
fi

API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$API_KEY_PATH")" && pwd -P)"
PKG_ABS_PATH="$(cd "$(dirname "$PKG_FILE")" && pwd -P)/$(basename "$PKG_FILE")"
export API_PRIVATE_KEYS_DIR

echo "📤 App Store Connect upload configuration:"
echo "   Package file: ${PKG_ABS_PATH}"
echo "   Platform: macos"
echo "   Apple ID: ${APPLE_ID}"
echo "   Bundle ID: ${BUNDLE_ID}"
echo "   Bundle short version: ${BUNDLE_SHORT_VERSION}"
echo "   Bundle version: ${BUNDLE_VERSION}"
echo "   API key ID: $(redact_value "$API_KEY_ID")"
echo "   API issuer ID: $(redact_value "$API_ISSUER_ID")"
echo "   API key path: ${API_KEY_PATH}"
echo "   API_PRIVATE_KEYS_DIR: ${API_PRIVATE_KEYS_DIR}"
if [ "$WAIT_FOR_PROCESSING" = true ]; then
    echo "   Wait mode: enabled"
else
    echo "   Wait mode: disabled"
fi

upload_args=(
    altool
    --upload-package "$PKG_ABS_PATH"
    --platform macos
    --apple-id "$APPLE_ID"
    --bundle-id "$BUNDLE_ID"
    --bundle-version "$BUNDLE_VERSION"
    --bundle-short-version-string "$BUNDLE_SHORT_VERSION"
    --api-key "$API_KEY_ID"
    --api-issuer "$API_ISSUER_ID"
)

if [ "$WAIT_FOR_PROCESSING" = true ]; then
    upload_args+=(--wait)
fi

echo "🚀 Uploading package to App Store Connect..."
upload_output=""
if ! upload_output=$(xcrun "${upload_args[@]}" 2>&1); then
    echo "$upload_output"
    fail "Upload command failed."
fi

echo "$upload_output"

if echo "$upload_output" | grep -Eq "UPLOAD FAILED|Failed to upload package\\.|Validation failed \\([0-9]+\\)|STATE_ERROR\\.|BUILD-STATUS: FAILED|PROCESSING-ERRORS:"; then
    fail "Upload command reported validation errors."
fi

echo "✅ Upload completed successfully."
