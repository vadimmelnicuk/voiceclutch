#!/bin/bash
# Build script for VoiceClutch macOS app
# Usage: ./build.sh [--production|-p] [--skip-certification] [--sign-identity "<Developer ID Application: Team (TEAMID)>"] [--notary-profile "<profile>"]

set -e

# Load local environment overrides (for signing/notarization secrets).
if [ -f ".env" ]; then
    set -a
    # shellcheck disable=SC1091
    source ".env"
    set +a
fi

# Parse arguments
CONFIGURATION="Debug"
BUILD_FOR_PRODUCTION=false
SKIP_PRODUCTION_CERTIFICATION=false
SIGN_IDENTITY="${VOICECLUTCH_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${VOICECLUTCH_NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${VOICECLUTCH_APPLE_ID:-}"
NOTARY_APP_PASSWORD="${VOICECLUTCH_APP_PASSWORD:-}"
NOTARY_TEAM_ID="${VOICECLUTCH_TEAM_ID:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --production|-p)
            CONFIGURATION="Release"
            BUILD_FOR_PRODUCTION=true
            shift
            ;;
        --skip-certification)
            SKIP_PRODUCTION_CERTIFICATION=true
            shift
            ;;
        --sign-identity)
            if [ -z "${2:-}" ]; then
                echo "Error: --sign-identity requires a value"
                exit 1
            fi
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --sign-identity=*)
            SIGN_IDENTITY="${1#*=}"
            shift
            ;;
        --notary-profile)
            if [ -z "${2:-}" ]; then
                echo "Error: --notary-profile requires a value"
                exit 1
            fi
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --notary-profile=*)
            NOTARY_PROFILE="${1#*=}"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--production|-p] [--skip-certification] [--sign-identity \"<Developer ID Application: Team (TEAMID)>\"] [--notary-profile \"<profile>\"]"
            echo ""
            echo "Options:"
            echo "  --production, -p    Build for production (Release configuration, no auto-launch)"
            echo "  --skip-certification Skip Developer ID signing/notarization for production builds"
            echo "  --sign-identity     Developer ID Application identity for codesign"
            echo "  --notary-profile    notarytool keychain profile name (recommended)"
            echo "  --help, -h          Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  VOICECLUTCH_SIGN_IDENTITY"
            echo "  VOICECLUTCH_NOTARY_PROFILE"
            echo "  VOICECLUTCH_APPLE_ID"
            echo "  VOICECLUTCH_APP_PASSWORD"
            echo "  VOICECLUTCH_TEAM_ID"
            echo ""
            echo "Notes:"
            echo "  If present, ./.env is loaded automatically before parsing arguments."
            echo "  --skip-certification can be used with --production for external signing workflows."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [ "$SKIP_PRODUCTION_CERTIFICATION" = true ] && [ "$BUILD_FOR_PRODUCTION" != true ]; then
    echo "Error: --skip-certification can only be used with --production." >&2
    exit 1
fi

APP_NAME="VoiceClutch"
PRODUCTION_BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "Resources/Info.plist" 2>/dev/null || true)
if [ -z "$PRODUCTION_BUNDLE_IDENTIFIER" ]; then
    PRODUCTION_BUNDLE_IDENTIFIER="com.vadimmelnicuk.voiceclutch"
fi
DEBUG_BUNDLE_IDENTIFIER="${PRODUCTION_BUNDLE_IDENTIFIER}.debug"
PRODUCTION_BUNDLE_NAME="${APP_NAME}"
DEBUG_BUNDLE_NAME="${APP_NAME} Debug"
HARDENED_RUNTIME_ENTITLEMENTS="Resources/VoiceClutch.entitlements"
if [ "$BUILD_FOR_PRODUCTION" = true ]; then
    APP_BUNDLE="${APP_NAME}.app"
    BUILD_DIR=".build/release"
else
    APP_BUNDLE="${APP_NAME}-Debug.app"
    BUILD_DIR=".build/debug"
fi
EXECUTABLE="${BUILD_DIR}/${APP_NAME}"
START_TIME=$(date +%s)
PID_FILE="/tmp/voiceclutch-debug.pid"

# Timestamp function matching app log format [HH:MM:SS.mmm]
timestamp() {
    date +"[%H:%M:%S.%3N]"
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

generate_icns_icon() {
    local source_png="$1"
    local output_icns="$2"
    local iconset_dir="$3"
    local size
    local retina_size

    if ! command -v sips >/dev/null 2>&1; then
        return 1
    fi
    if ! command -v iconutil >/dev/null 2>&1; then
        return 1
    fi

    rm -rf "$iconset_dir"
    mkdir -p "$iconset_dir"

    for size in 16 32 128 256 512; do
        retina_size=$((size * 2))
        sips -z "$size" "$size" "$source_png" --out "${iconset_dir}/icon_${size}x${size}.png" >/dev/null
        sips -z "$retina_size" "$retina_size" "$source_png" --out "${iconset_dir}/icon_${size}x${size}@2x.png" >/dev/null
    done

    iconutil -c icns "$iconset_dir" -o "$output_icns"
}

set_plist_string_value() {
    local plist_path="$1"
    local key="$2"
    local value="$3"

    if /usr/libexec/PlistBuddy -c "Print :${key}" "$plist_path" >/dev/null 2>&1; then
        plutil -replace "$key" -string "$value" "$plist_path"
    else
        plutil -insert "$key" -string "$value" "$plist_path"
    fi
}

configure_app_bundle_identity() {
    local plist_path="$1"
    local bundle_identifier
    local bundle_name

    if [ "$BUILD_FOR_PRODUCTION" = true ]; then
        bundle_identifier="$PRODUCTION_BUNDLE_IDENTIFIER"
        bundle_name="$PRODUCTION_BUNDLE_NAME"
    else
        bundle_identifier="$DEBUG_BUNDLE_IDENTIFIER"
        bundle_name="$DEBUG_BUNDLE_NAME"
    fi

    set_plist_string_value "$plist_path" "CFBundleIdentifier" "$bundle_identifier"
    set_plist_string_value "$plist_path" "CFBundleName" "$bundle_name"
    set_plist_string_value "$plist_path" "CFBundleDisplayName" "$bundle_name"
}

codesign_with_hints() {
    local target="$1"
    shift

    local output
    if ! output=$(codesign "$@" "$target" 2>&1); then
        if [ -n "$output" ]; then
            echo "$output" >&2
        fi
        if echo "$output" | grep -q "errSecInternalComponent"; then
            echo "Hint: errSecInternalComponent often means a keychain trust/access issue." >&2
            echo "Hint: verify your Developer ID cert chain and private-key access in Keychain Access." >&2
            echo "Hint: if running from automation, ensure the keychain is unlocked and codesign is allowed to use the key." >&2
        fi
        fail "codesign failed for ${target}"
    fi

    if [ -n "$output" ]; then
        echo "$output"
    fi
}

validate_production_certification_requirements() {
    if [ "$BUILD_FOR_PRODUCTION" != true ]; then
        return
    fi

    if [ "$SKIP_PRODUCTION_CERTIFICATION" = true ]; then
        return
    fi

    if [ -z "$SIGN_IDENTITY" ]; then
        fail "Production builds require signing identity. Pass --sign-identity or set VOICECLUTCH_SIGN_IDENTITY."
    fi

    require_command codesign
    require_command spctl
    require_command xcrun
    require_command ditto

    if [ ! -f "$HARDENED_RUNTIME_ENTITLEMENTS" ]; then
        fail "Missing entitlements file required for production signing: ${HARDENED_RUNTIME_ENTITLEMENTS}"
    fi

    if ! xcrun --find notarytool >/dev/null 2>&1; then
        fail "xcrun notarytool is not available. Install Xcode command line tools with notarization support."
    fi

    if ! xcrun --find stapler >/dev/null 2>&1; then
        fail "xcrun stapler is not available. Install Xcode command line tools with stapler support."
    fi

    if [ -n "$NOTARY_PROFILE" ]; then
        return
    fi

    local missing=()
    if [ -z "$NOTARY_APPLE_ID" ]; then
        missing+=("VOICECLUTCH_APPLE_ID")
    fi
    if [ -z "$NOTARY_APP_PASSWORD" ]; then
        missing+=("VOICECLUTCH_APP_PASSWORD")
    fi
    if [ -z "$NOTARY_TEAM_ID" ]; then
        missing+=("VOICECLUTCH_TEAM_ID")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        fail "Notarization credentials missing. Provide --notary-profile/VOICECLUTCH_NOTARY_PROFILE or set ${missing[*]}."
    fi
}

sign_nested_code() {
    local app_path="$1"
    local target
    local bundle_path
    local bundle_executable
    local bundle_executable_path
    local count=0

    # Sign binary code payloads first.
    while IFS= read -r target; do
        if [ -z "$target" ] || [ "$target" = "$app_path" ]; then
            continue
        fi

        echo "🔏 Signing nested target: ${target}"
        codesign_with_hints "$target" \
            --force \
            --timestamp \
            --sign "$SIGN_IDENTITY"
        count=$((count + 1))
    done < <(
        find "$app_path" -depth \
            \( \
                -type d \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" \) \
                -o -type f \( -name "*.dylib" -o -name "*.so" \) \
            \) \
            -print
    )

    # Only sign loadable bundles that declare an executable.
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
            --timestamp \
            --sign "$SIGN_IDENTITY"
        count=$((count + 1))
    done < <(find "$app_path" -depth -type d -name "*.bundle" -print)

    echo "✅ Signed ${count} nested code target(s)"
}

verify_signing_and_gatekeeper() {
    local app_path="$1"
    local phase="$2"
    local enforce_gatekeeper="${3:-true}"

    echo "🔎 Verifying code signature (${phase})..."
    codesign --verify --deep --strict --verbose=2 "$app_path"

    echo "🛡️  Running Gatekeeper assessment (${phase})..."
    if ! spctl --assess --type execute --verbose=4 "$app_path"; then
        if [ "$enforce_gatekeeper" = true ]; then
            fail "Gatekeeper assessment failed (${phase})."
        fi
        echo "⚠️  Gatekeeper rejected app during ${phase}. This is expected before notarization; continuing."
    fi
}

notarize_and_staple() {
    local app_path="$1"
    local archive_path="$2"

    mkdir -p "$(dirname "$archive_path")"
    rm -f "$archive_path"

    echo "📦 Creating notarization archive: ${archive_path}"
    ditto -c -k --keepParent "$app_path" "$archive_path"

    if [ -n "$NOTARY_PROFILE" ]; then
        echo "📤 Submitting app for notarization with keychain profile '${NOTARY_PROFILE}'..."
        xcrun notarytool submit "$archive_path" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait
    else
        echo "📤 Submitting app for notarization with Apple ID credentials from environment..."
        xcrun notarytool submit "$archive_path" \
            --apple-id "$NOTARY_APPLE_ID" \
            --password "$NOTARY_APP_PASSWORD" \
            --team-id "$NOTARY_TEAM_ID" \
            --wait
    fi

    echo "📎 Stapling notarization ticket..."
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
}

certify_production_app_bundle() {
    local app_path="$1"
    local archive_dir=".build/notary"
    local archive_path="${archive_dir}/${APP_NAME}-notarization.zip"
    local app_abs_path
    local archive_abs_path

    echo "🔐 Starting production certification..."
    echo "   Signing identity: ${SIGN_IDENTITY}"
    if [ -n "$NOTARY_PROFILE" ]; then
        echo "   Notarization auth: keychain profile (${NOTARY_PROFILE})"
    else
        echo "   Notarization auth: Apple ID environment credentials"
    fi

    sign_nested_code "$app_path"

    echo "🔏 Signing app bundle with Hardened Runtime..."
    codesign_with_hints "$app_path" \
        --deep \
        --force \
        --timestamp \
        --options runtime \
        --entitlements "$HARDENED_RUNTIME_ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY"

    verify_signing_and_gatekeeper "$app_path" "pre-notarization" "false"
    notarize_and_staple "$app_path" "$archive_path"
    verify_signing_and_gatekeeper "$app_path" "post-stapling" "true"

    app_abs_path="$(cd "$(dirname "$app_path")" && pwd -P)/$(basename "$app_path")"
    archive_abs_path="$(cd "$(dirname "$archive_path")" && pwd -P)/$(basename "$archive_path")"

    echo "✅ Production app signed, notarized, and stapled."
    echo "   App bundle: ${app_abs_path}"
    echo "   Notarization archive: ${archive_abs_path}"
}

terminate_pid_gracefully() {
    local pid="$1"
    local label="$2"

    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        return
    fi

    echo "🧹 Stopping ${label} process (pid ${pid})..."
    kill -TERM "$pid" 2>/dev/null || true

    local retries=20
    while [ "$retries" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.25
        retries=$((retries - 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        echo "⚠️  Process ${pid} did not stop after SIGTERM; sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

terminate_matching_processes() {
    local needle="$1"
    local label="$2"
    local pids

    pids=""
    while IFS= read -r line; do
        local pid cmd
        pid="${line%% *}"
        cmd="${line#* }"

        if [ -z "$pid" ] || [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; then
            continue
        fi

        case "$cmd" in
            *"$needle"*)
                case "$cmd" in
                    *"Scripts/build.sh"*)
                        continue
                        ;;
                esac
                pids="${pids}${pids:+ }${pid}"
                ;;
        esac
    done < <(ps ax -o pid= -o command=)

    if [ -z "$pids" ]; then
        return
    fi

    echo "⚠️  Found stale ${label} process(es): ${pids}"
    for pid in $pids; do
        terminate_pid_gracefully "$pid" "$label"
    done
}

terminate_processes_by_name() {
    local process_name="$1"
    local label="$2"
    local pids

    pids=$(ps ax -o pid= -o comm= | awk -v app="$process_name" '$2 == app { print $1 }')
    if [ -z "$pids" ]; then
        return
    fi

    echo "⚠️  Found stale ${label} process(es): ${pids}"
    for pid in $pids; do
        terminate_pid_gracefully "$pid" "$label"
    done
}

terminate_stale_debug_processes() {
    local workspace_path
    local debug_bundle_exec_abs
    local debug_bundle_exec_rel
    local swift_debug_exec_abs
    local swift_debug_exec_arch_abs

    workspace_path="$(pwd -P)"
    debug_bundle_exec_abs="${workspace_path}/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
    debug_bundle_exec_rel="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
    swift_debug_exec_abs="${workspace_path}/.build/debug/${APP_NAME}"
    swift_debug_exec_arch_abs="${workspace_path}/.build/arm64-apple-macosx/debug/${APP_NAME}"

    terminate_matching_processes "$debug_bundle_exec_abs" "debug bundle"
    terminate_matching_processes "$debug_bundle_exec_rel" "debug bundle"
    terminate_matching_processes "$swift_debug_exec_abs" "Swift debug"
    terminate_matching_processes "$swift_debug_exec_arch_abs" "Swift debug"
    terminate_processes_by_name "$APP_NAME" "VoiceClutch"

    if [ -f "$PID_FILE" ]; then
        local recorded_pid
        recorded_pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ "$recorded_pid" =~ ^[0-9]+$ ]]; then
            terminate_pid_gracefully "$recorded_pid" "recorded debug"
        fi
        rm -f "$PID_FILE"
    fi
}

validate_production_certification_requirements

if [ "$BUILD_FOR_PRODUCTION" = true ]; then
    echo "$(timestamp) 🔨 Building VoiceClutch (Release)"
    XCODE_BUILD_DIR=".build/arm64-apple-macosx/release"
    CONFIG="Release"
else
    echo "$(timestamp) 🔨 Building VoiceClutch (Debug)"
    XCODE_BUILD_DIR=".build/arm64-apple-macosx/debug"
    CONFIG="Debug"
fi

SWIFT_CONFIG="$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
MLX_BUNDLE_NAME="mlx-swift_Cmlx.bundle"
XCODE_DERIVED_DATA_PATH=".build/xcode-derived-data"
XCODE_PRODUCTS_DIR="${XCODE_DERIVED_DATA_PATH}/Build/Products/${CONFIG}"
METAL_CACHE_DIR=".build/metal-cache/${CONFIG}"
CACHED_MLX_BUNDLE="${METAL_CACHE_DIR}/${MLX_BUNDLE_NAME}"
METAL_CACHE_STAMP="${METAL_CACHE_DIR}/shader-cache.stamp"

should_rebuild_metal_shaders() {
    local shader_input_mtime=0
    local file_mtime
    local mlx_metal_max_mtime

    for tracked_file in "Package.swift" "Package.resolved"; do
        if [ -f "$tracked_file" ]; then
            file_mtime=$(stat -f "%m" "$tracked_file" 2>/dev/null || echo "0")
            if [ "$file_mtime" -gt "$shader_input_mtime" ]; then
                shader_input_mtime="$file_mtime"
            fi
        fi
    done

    if [ -d ".build/checkouts/mlx-swift" ]; then
        mlx_metal_max_mtime=$(
            find ".build/checkouts/mlx-swift" -type f \( -name "*.metal" -o -name "*.metallib" \) \
                -exec stat -f "%m" {} \; 2>/dev/null | sort -nr | head -1
        )
        if [ -n "$mlx_metal_max_mtime" ] && [ "$mlx_metal_max_mtime" -gt "$shader_input_mtime" ]; then
            shader_input_mtime="$mlx_metal_max_mtime"
        fi
    fi

    if [ ! -d "$CACHED_MLX_BUNDLE" ] || [ ! -f "$METAL_CACHE_STAMP" ]; then
        return 0
    fi

    local cache_stamp_mtime
    cache_stamp_mtime=$(stat -f "%m" "$METAL_CACHE_STAMP" 2>/dev/null || echo "0")
    if [ "$cache_stamp_mtime" -ge "$shader_input_mtime" ]; then
        return 1
    fi
    return 0
}

if should_rebuild_metal_shaders; then
    # Use xcodebuild to build with Metal shader support only when shader inputs changed.
    echo "Building with xcodebuild to compile Metal shaders..."
    if xcodebuild \
        -scheme VoiceClutch \
        -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        -derivedDataPath "$XCODE_DERIVED_DATA_PATH" \
        build; then
        echo "✅ xcodebuild successful"
        USE_XCODEBUILD=true

        if [ -d "$XCODE_PRODUCTS_DIR/$MLX_BUNDLE_NAME" ]; then
            mkdir -p "$METAL_CACHE_DIR"
            rm -rf "$CACHED_MLX_BUNDLE"
            cp -R "$XCODE_PRODUCTS_DIR/$MLX_BUNDLE_NAME" "$CACHED_MLX_BUNDLE"
            touch "$METAL_CACHE_STAMP"
            echo "♻️  Updated cached MLX Metal shader bundle"
        fi
    else
        # If xcodebuild fails (no scheme), fall back to swift build.
        echo "⚠️  xcodebuild failed, using swift build"
        echo "⚠️  Note: Metal shaders require Xcode to build properly"
        swift build -c "$SWIFT_CONFIG"
        USE_XCODEBUILD=false
    fi
else
    echo "♻️  Reusing cached MLX Metal shader bundle (skipping xcodebuild)"
    swift build -c "$SWIFT_CONFIG"
    USE_XCODEBUILD=false
fi

# Set the correct executable path based on what was built
if [ "$USE_XCODEBUILD" = true ]; then
    if [ -f "$XCODE_PRODUCTS_DIR/$APP_NAME" ]; then
        EXECUTABLE="$XCODE_PRODUCTS_DIR/$APP_NAME"
    else
        echo "Error: Could not find built executable in Xcode DerivedData"
        exit 1
    fi
elif [ -f "$XCODE_BUILD_DIR/$APP_NAME" ]; then
    EXECUTABLE="$XCODE_BUILD_DIR/$APP_NAME"
elif [ -f ".build/debug/$APP_NAME" ]; then
    EXECUTABLE=".build/debug/$APP_NAME"
elif [ -f ".build/release/$APP_NAME" ]; then
    EXECUTABLE=".build/release/$APP_NAME"
else
    echo "Error: Could not find built executable"
    exit 1
fi

END_TIME=$(date +%s)
BUILD_TIME=$((END_TIME - START_TIME))
MINUTES=$((BUILD_TIME / 60))
SECONDS=$((BUILD_TIME % 60))
echo "⏱️  Build time: ${MINUTES}m ${SECONDS}s"

echo "📦 Creating .app bundle..."

# Remove existing .app if it exists
rm -rf "${APP_BUNDLE}"

# Create .app bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy executable
cp "${EXECUTABLE}" "${APP_BUNDLE}/Contents/MacOS/"

# Copy Info.plist
if [ -f "Resources/Info.plist" ]; then
    APP_PLIST_PATH="${APP_BUNDLE}/Contents/Info.plist"
    cp "Resources/Info.plist" "${APP_PLIST_PATH}"
    configure_app_bundle_identity "${APP_PLIST_PATH}"
else
    echo "⚠️  Warning: Resources/Info.plist not found"
fi

# Copy toolbar icon assets
ICON_FILES=("logo@1x.png" "logo@2x.png" "logo@3x.png")
for icon_file in "${ICON_FILES[@]}"; do
    if [ -f "Resources/${icon_file}" ]; then
        cp "Resources/${icon_file}" "${APP_BUNDLE}/Contents/Resources/${icon_file}"
    else
        echo "⚠️  Warning: Toolbar icon asset not found (Resources/${icon_file})"
    fi
done

# Copy GitHub icon used in Preferences footer button
GITHUB_ICON_FILE="GitHub_Invertocat_White_Clearspace.svg"
if [ -f "Resources/${GITHUB_ICON_FILE}" ]; then
    cp "Resources/${GITHUB_ICON_FILE}" "${APP_BUNDLE}/Contents/Resources/${GITHUB_ICON_FILE}"
else
    echo "⚠️  Warning: GitHub icon asset not found (Resources/${GITHUB_ICON_FILE})"
fi

# Copy app icon assets (PNG + generated ICNS for App Store validation).
APP_ICON_SOURCE="Resources/VoiceClutch.png"
APP_ICON_PNG_DEST="${APP_BUNDLE}/Contents/Resources/VoiceClutch.png"
APP_ICON_ICNS_DEST="${APP_BUNDLE}/Contents/Resources/VoiceClutch.icns"
APP_ICONSET_DIR=".build/iconset/VoiceClutch.iconset"

if [ -f "$APP_ICON_SOURCE" ]; then
    cp "$APP_ICON_SOURCE" "$APP_ICON_PNG_DEST"
    if generate_icns_icon "$APP_ICON_SOURCE" "$APP_ICON_ICNS_DEST" "$APP_ICONSET_DIR"; then
        echo "📦 Generated app icon ICNS: ${APP_ICON_ICNS_DEST}"
    else
        if [ "$BUILD_FOR_PRODUCTION" = true ]; then
            fail "Failed to generate required macOS ICNS app icon for production build."
        fi
        echo "⚠️  Warning: Failed to generate macOS ICNS app icon."
    fi
else
    if [ "$BUILD_FOR_PRODUCTION" = true ]; then
        fail "App icon source file not found: ${APP_ICON_SOURCE}"
    fi
    echo "⚠️  Warning: App icon source file not found (${APP_ICON_SOURCE})"
fi

# Copy chime assets used by MicrophoneChimePlayer.
if [ -d "Resources/Chimes" ]; then
    cp -R "Resources/Chimes" "${APP_BUNDLE}/Contents/Resources/"
else
    echo "⚠️  Warning: Chime assets folder not found (Resources/Chimes)"
fi

# Copy MLX bundle (containing Metal shaders) to app bundle
# This is required for MLX to find the compiled metallib at runtime
if [ -d "$XCODE_PRODUCTS_DIR/$MLX_BUNDLE_NAME" ]; then
    echo "📦 Copying MLX Metal shader bundle..."
    cp -R "$XCODE_PRODUCTS_DIR/$MLX_BUNDLE_NAME" "${APP_BUNDLE}/Contents/Resources/"
    echo "   Copied: $XCODE_PRODUCTS_DIR/$MLX_BUNDLE_NAME"
elif [ -d "$CACHED_MLX_BUNDLE" ]; then
    echo "📦 Copying cached MLX Metal shader bundle..."
    cp -R "$CACHED_MLX_BUNDLE" "${APP_BUNDLE}/Contents/Resources/"
    echo "   Copied: $CACHED_MLX_BUNDLE"
elif [ -n "$XCODE_PRODUCTS_DIR" ]; then
    # Try to find the MLX bundle in DerivedData
    DERIVED_DATA_MLX=$(find ~/Library/Developer/Xcode/DerivedData -name "$MLX_BUNDLE_NAME" -type d 2>/dev/null | head -1)
    if [ -n "$DERIVED_DATA_MLX" ]; then
        echo "📦 Copying MLX Metal shader bundle from DerivedData..."
        cp -R "$DERIVED_DATA_MLX" "${APP_BUNDLE}/Contents/Resources/"
        echo "   Copied: $DERIVED_DATA_MLX"
    else
        echo "⚠️  Warning: MLX bundle not found - Metal shaders may not work"
        echo "   Searched in: $XCODE_PRODUCTS_DIR and DerivedData"
    fi
else
    echo "⚠️  Warning: MLX bundle not found - Metal shaders may not work"
fi

echo "$(timestamp) ✅ Build successful!"
echo ""
echo "App bundle location: ${APP_BUNDLE}"

if [ "$BUILD_FOR_PRODUCTION" = true ]; then
    if [ "$SKIP_PRODUCTION_CERTIFICATION" = true ]; then
        echo "⏭️  Skipping production certification (--skip-certification)."
        echo ""
        echo "📦 Production bundle created."
        echo "   App bundle is ready for external signing/packaging workflows."
    else
        certify_production_app_bundle "${APP_BUNDLE}"
        echo ""
        echo "📦 Production bundle created."
        echo "   The app is ready for Developer ID distribution."
    fi
else
    echo "🔏 Applying stable ad-hoc signature for debug app identity..."
    codesign --force --deep --sign - --identifier "$DEBUG_BUNDLE_IDENTIFIER" "${APP_BUNDLE}"

    echo ""
    echo "🚀 Launching app in debug mode (logs will appear in terminal)..."
    echo "Press Ctrl+C to stop the app"
    echo ""

    terminate_stale_debug_processes

    APP_PID=""
    SHUTDOWN_SIGNAL=""
    stop_launched_app() {
        local pid="${APP_PID:-}"

        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            return
        fi

        echo ""
        echo "🛑 Stopping app (pid ${pid})..."
        terminate_pid_gracefully "$pid" "launched app"
        rm -f "$PID_FILE"
    }

    trap 'SHUTDOWN_SIGNAL="HUP"; stop_launched_app' HUP
    trap 'SHUTDOWN_SIGNAL="INT"; stop_launched_app' INT
    trap 'SHUTDOWN_SIGNAL="TERM"; stop_launched_app' TERM
    trap stop_launched_app EXIT
    APP_EXEC_PATH="$(pwd -P)/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
    "$APP_EXEC_PATH" &
    APP_PID=$!
    echo "$APP_PID" > "$PID_FILE"

    set +e
    wait "$APP_PID"
    APP_EXIT_CODE=$?
    set -e

    APP_PID=""
    rm -f "$PID_FILE"
    trap - HUP INT TERM EXIT

    if [ -n "$SHUTDOWN_SIGNAL" ]; then
        exit 0
    fi

    exit "$APP_EXIT_CODE"
fi
