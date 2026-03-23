#!/bin/bash
# Bundle a built VoiceClutch app into a distributable DMG.
# Usage: ./bundle-dmg.sh [--app <path>] [--output <path>] [--volume-name <name>] [--background <path>] [--plain]

set -euo pipefail

APP_PATH="VoiceClutch.app"
OUTPUT_PATH=""
OUTPUT_PATH_SET=false
VOLUME_NAME="VoiceClutch"
STYLE_DMG=true
BACKGROUND_PATH=""
BACKGROUND_FILE_NAME=""
TMP_DIR=""
RW_DMG_PATH=""
MOUNT_DEVICE=""
MOUNT_POINT=""
VERIFY_DEVICE=""
VERIFY_MOUNT_POINT=""

usage() {
    cat <<'USAGE'
Usage: ./bundle-dmg.sh [options]

Bundle a built .app into a compressed DMG with an Applications shortcut.
This script uses only native macOS tooling (hdiutil + Finder AppleScript).

Options:
  --app <path>          Path to .app bundle (default: VoiceClutch.app)
  --output <path>       Output DMG path (default: <app-name>-<version>-<platform>.dmg)
  --volume-name <name>  Mounted DMG volume name (default: VoiceClutch)
  --background <path>   PNG/JPG background image for Finder window
  --plain               Skip Finder layout styling for headless/CI usage
  --help, -h            Show this help message
USAGE
}

detach_mounted_device() {
    local device="$1"

    if [ -z "$device" ]; then
        return
    fi

    if hdiutil detach "$device" -quiet >/dev/null 2>&1; then
        return
    fi

    sleep 1
    hdiutil detach "$device" -force -quiet >/dev/null 2>&1 || true
}

cleanup() {
    if [ -n "${VERIFY_DEVICE:-}" ]; then
        detach_mounted_device "$VERIFY_DEVICE"
        VERIFY_DEVICE=""
    fi

    if [ -n "${MOUNT_DEVICE:-}" ]; then
        detach_mounted_device "$MOUNT_DEVICE"
        MOUNT_DEVICE=""
    fi

    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

calculate_dmg_size_mb() {
    local app_path="$1"
    local bg_path="$2"
    local app_kb
    local bg_kb=0
    local total_kb
    local total_mb

    app_kb="$(du -sk "$app_path" | awk '{print $1}')"
    if [ -n "$bg_path" ] && [ -f "$bg_path" ]; then
        bg_kb="$(du -sk "$bg_path" | awk '{print $1}')"
    fi

    # Include room for filesystem overhead and Finder metadata.
    total_kb=$((app_kb + bg_kb + (60 * 1024)))
    total_mb=$(((total_kb + 1023) / 1024))
    if [ "$total_mb" -lt 100 ]; then
        total_mb=100
    fi

    echo "$total_mb"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            if [ -z "${2:-}" ]; then
                echo "Error: --app requires a value" >&2
                exit 1
            fi
            APP_PATH="$2"
            shift 2
            ;;
        --app=*)
            APP_PATH="${1#*=}"
            shift
            ;;
        --output)
            if [ -z "${2:-}" ]; then
                echo "Error: --output requires a value" >&2
                exit 1
            fi
            OUTPUT_PATH="$2"
            OUTPUT_PATH_SET=true
            shift 2
            ;;
        --output=*)
            OUTPUT_PATH="${1#*=}"
            OUTPUT_PATH_SET=true
            shift
            ;;
        --volume-name)
            if [ -z "${2:-}" ]; then
                echo "Error: --volume-name requires a value" >&2
                exit 1
            fi
            VOLUME_NAME="$2"
            shift 2
            ;;
        --volume-name=*)
            VOLUME_NAME="${1#*=}"
            shift
            ;;
        --background)
            if [ -z "${2:-}" ]; then
                echo "Error: --background requires a value" >&2
                exit 1
            fi
            BACKGROUND_PATH="$2"
            shift 2
            ;;
        --background=*)
            BACKGROUND_PATH="${1#*=}"
            shift
            ;;
        --plain)
            STYLE_DMG=false
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if ! command -v hdiutil >/dev/null 2>&1; then
    echo "Error: hdiutil not found (required on macOS)." >&2
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App bundle not found: $APP_PATH" >&2
    echo "Build it first, for example: ./Scripts/build.sh --production" >&2
    exit 1
fi

if [ -n "$BACKGROUND_PATH" ] && [ ! -f "$BACKGROUND_PATH" ]; then
    echo "Error: Background image not found: $BACKGROUND_PATH" >&2
    exit 1
fi

if [ "$STYLE_DMG" = true ] && ! command -v osascript >/dev/null 2>&1; then
    echo "Warning: osascript not found. Falling back to plain DMG." >&2
    STYLE_DMG=false
fi

APP_BASENAME="$(basename "$APP_PATH")"
APP_FILE_NAME="${APP_BASENAME%.app}"
APP_INFO_PLIST_PATH="${APP_PATH}/Contents/Info.plist"
APP_EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${APP_FILE_NAME}"
APP_PLATFORM="$(uname -m)"

if [ "$OUTPUT_PATH_SET" = false ]; then
    APP_VERSION="$(
        /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_INFO_PLIST_PATH" 2>/dev/null || true
    )"
    if [ -z "$APP_VERSION" ]; then
        echo "Error: Could not determine CFBundleShortVersionString from ${APP_INFO_PLIST_PATH}" >&2
        echo "Pass --output explicitly or ensure the app bundle has a short version string." >&2
        exit 1
    fi
    if [ -f "$APP_EXECUTABLE_PATH" ] && command -v lipo >/dev/null 2>&1; then
        APP_ARCHS="$(lipo -archs "$APP_EXECUTABLE_PATH" 2>/dev/null | xargs || true)"
        if [ -n "$APP_ARCHS" ]; then
            APP_PLATFORM="$(echo "$APP_ARCHS" | tr ' ' '-')"
        fi
    fi
    OUTPUT_PATH="${APP_FILE_NAME}-${APP_VERSION}-${APP_PLATFORM}.dmg"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"

TMP_DIR="$(mktemp -d /tmp/voiceclutch-dmg.XXXXXX)"
RW_DMG_PATH="${TMP_DIR}/VoiceClutch-temp.dmg"
VERIFY_MOUNT_POINT="${TMP_DIR}/verify-mount"

if [ "$STYLE_DMG" = true ] && [ -n "$BACKGROUND_PATH" ]; then
    BACKGROUND_FILE_NAME="$(basename "$BACKGROUND_PATH")"
fi

DMG_SIZE_MB="$(calculate_dmg_size_mb "$APP_PATH" "$BACKGROUND_PATH")"

echo "📦 Creating temporary writable DMG (${DMG_SIZE_MB} MB)..."
hdiutil create \
    -size "${DMG_SIZE_MB}m" \
    -fs HFS+ \
    -volname "$VOLUME_NAME" \
    -ov \
    "$RW_DMG_PATH" >/dev/null

echo "💿 Mounting temporary DMG..."
ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG_PATH" -readwrite -noverify -noautoopen)"
MOUNT_DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/^\/dev\// { print $1; exit }' | xargs)"
MOUNT_POINT="$(echo "$ATTACH_OUTPUT" | sed -n 's#^.*\(/Volumes/.*\)$#\1#p' | head -1 | sed 's/[[:space:]]*$//')"

if [ -z "$MOUNT_DEVICE" ] || [ -z "$MOUNT_POINT" ]; then
    echo "Error: Failed to mount writable DMG." >&2
    exit 1
fi

echo "📁 Copying app and Applications shortcut..."
cp -R "$APP_PATH" "${MOUNT_POINT}/${APP_BASENAME}"
ln -s /Applications "${MOUNT_POINT}/Applications"

if [ "$STYLE_DMG" = true ]; then
    if [ -n "$BACKGROUND_FILE_NAME" ]; then
        mkdir -p "${MOUNT_POINT}/.background"
        cp "$BACKGROUND_PATH" "${MOUNT_POINT}/.background/${BACKGROUND_FILE_NAME}"
    fi

    echo "🎨 Applying Finder layout..."
    MOUNT_NAME="$(basename "$MOUNT_POINT")"
    STYLE_RESULT="$(
        osascript - "$MOUNT_NAME" "$APP_BASENAME" "$MOUNT_POINT" "$BACKGROUND_FILE_NAME" <<'APPLESCRIPT'
on run argv
    set diskName to item 1 of argv
    set appItemName to item 2 of argv
    set mountPath to item 3 of argv
    set bgFileName to item 4 of argv

    tell application "Finder"
        tell disk diskName
            -- First pass: apply layout and persist.
            open
            delay 1

            set win to container window
            set current view of win to icon view
            set toolbar visible of win to false
            set statusbar visible of win to false
            set bounds of win to {90, 90, 1070, 650}

            set opts to icon view options of win
            set arrangement of opts to not arranged
            set icon size of opts to 128
            set text size of opts to 16
            set immediateSize to icon size of opts

            if bgFileName is not "" then
                set bgPath to mountPath & "/.background/" & bgFileName
                set background picture of opts to (POSIX file bgPath as alias)
            end if

            set position of item appItemName of win to {200, 220}
            set position of item "Applications" of win to {640, 220}

            update without registering applications
            delay 1
            close

            -- Second pass: re-apply to ensure Finder writes stable metadata.
            open
            delay 1
            set reopenedWin to container window
            set current view of reopenedWin to icon view
            set toolbar visible of reopenedWin to false
            set statusbar visible of reopenedWin to false
            set bounds of reopenedWin to {90, 90, 1070, 650}
            set reopenedOpts to icon view options of reopenedWin
            set arrangement of reopenedOpts to not arranged
            set icon size of reopenedOpts to 128
            set text size of reopenedOpts to 16

            if bgFileName is not "" then
                set bgPath to mountPath & "/.background/" & bgFileName
                set background picture of reopenedOpts to (POSIX file bgPath as alias)
            end if

            set position of item appItemName of reopenedWin to {200, 220}
            set position of item "Applications" of reopenedWin to {640, 220}

            update without registering applications
            delay 1
            set reopenedSize to icon size of reopenedOpts
            set appPosition to position of item appItemName of reopenedWin
            set applicationsPosition to position of item "Applications" of reopenedWin
            close

            return ((immediateSize as string) & "," & (reopenedSize as string) & "," & (item 1 of appPosition as string) & "," & (item 2 of appPosition as string) & "," & (item 1 of applicationsPosition as string) & "," & (item 2 of applicationsPosition as string))
        end tell
    end tell
end run
APPLESCRIPT
    )"

    STYLE_IMMEDIATE_SIZE="$(echo "$STYLE_RESULT" | awk -F',' '{print $1}')"
    STYLE_REOPEN_SIZE="$(echo "$STYLE_RESULT" | awk -F',' '{print $2}')"
    if [[ ! "$STYLE_IMMEDIATE_SIZE" =~ ^[0-9]+$ ]] || [[ ! "$STYLE_REOPEN_SIZE" =~ ^[0-9]+$ ]]; then
        echo "Error: Finder layout did not return valid icon sizes." >&2
        exit 1
    fi
    if [ "$STYLE_IMMEDIATE_SIZE" -lt 96 ] || [ "$STYLE_REOPEN_SIZE" -lt 96 ]; then
        echo "Error: Finder icon size did not persist (immediate=${STYLE_IMMEDIATE_SIZE}, reopened=${STYLE_REOPEN_SIZE})." >&2
        exit 1
    fi
    echo "✅ Finder layout applied: immediate=${STYLE_IMMEDIATE_SIZE}, reopened=${STYLE_REOPEN_SIZE}"
fi

echo "💾 Finalizing writable image..."
sync
if [ "$STYLE_DMG" = true ]; then
    for _ in {1..8}; do
        if [ -f "${MOUNT_POINT}/.DS_Store" ]; then
            break
        fi
        sleep 0.5
    done

    if [ ! -f "${MOUNT_POINT}/.DS_Store" ]; then
        echo "Warning: Finder metadata (.DS_Store) was not detected before detach." >&2
    fi
fi

detach_mounted_device "$MOUNT_DEVICE"
MOUNT_DEVICE=""

echo "📦 Creating final compressed DMG..."
hdiutil convert "$RW_DMG_PATH" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$OUTPUT_PATH" >/dev/null

if [ "$STYLE_DMG" = true ]; then
    mkdir -p "$VERIFY_MOUNT_POINT"
    if VERIFY_ATTACH_OUTPUT="$(hdiutil attach "$OUTPUT_PATH" -readonly -nobrowse -mountpoint "$VERIFY_MOUNT_POINT" 2>/dev/null)"; then
        VERIFY_DEVICE="$(echo "$VERIFY_ATTACH_OUTPUT" | awk '/^\/dev\// { print $1; exit }' | xargs)"
        VERIFY_MOUNT_NAME="$(basename "$VERIFY_MOUNT_POINT")"
        VERIFY_ICON_SIZE=""

        if [ ! -f "$VERIFY_MOUNT_POINT/.DS_Store" ]; then
            echo "Error: Finder layout metadata missing in final DMG." >&2
            exit 1
        fi

        if [ -n "$BACKGROUND_FILE_NAME" ] && [ ! -f "$VERIFY_MOUNT_POINT/.background/$BACKGROUND_FILE_NAME" ]; then
            echo "Error: DMG background missing in final DMG." >&2
            exit 1
        fi

        if command -v osascript >/dev/null 2>&1; then
            VERIFY_ICON_SIZE="$(
                osascript - "$VERIFY_MOUNT_NAME" <<'APPLESCRIPT'
on run argv
    set diskName to item 1 of argv
    tell application "Finder"
        tell disk diskName
            open
            delay 0.5
            set s to icon size of (icon view options of container window)
            close
            return (s as string)
        end tell
    end tell
end run
APPLESCRIPT
            )"
            if [[ ! "$VERIFY_ICON_SIZE" =~ ^[0-9]+$ ]]; then
                echo "Error: Could not read icon size from final DMG Finder settings." >&2
                exit 1
            fi
            if [ "$VERIFY_ICON_SIZE" -lt 96 ]; then
                echo "Error: Final DMG icon size is too small (${VERIFY_ICON_SIZE})." >&2
                exit 1
            fi
        fi

        echo "✅ Finder layout metadata embedded."
        if [ -n "$VERIFY_ICON_SIZE" ]; then
            echo "✅ Final DMG icon size: ${VERIFY_ICON_SIZE}"
        fi
        detach_mounted_device "$VERIFY_DEVICE"
        VERIFY_DEVICE=""
    else
        echo "Warning: Could not verify Finder metadata in final DMG." >&2
    fi
fi

OUTPUT_ABS_PATH="$(cd "$(dirname "$OUTPUT_PATH")" && pwd -P)/$(basename "$OUTPUT_PATH")"
echo "✅ DMG created: ${OUTPUT_ABS_PATH}"
