#!/bin/bash
# Build script for VoiceClutch macOS app
# Usage: ./build.sh [--production|-p]

set -e

# Parse arguments
CONFIGURATION="Debug"
BUILD_FOR_PRODUCTION=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --production|-p)
            CONFIGURATION="Release"
            BUILD_FOR_PRODUCTION=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--production|-p]"
            echo ""
            echo "Options:"
            echo "  --production, -p    Build for production (Release configuration, no auto-launch)"
            echo "  --help, -h          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

APP_NAME="VoiceClutch"
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
    cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/"
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

# Copy app icon
if [ -f "Resources/VoiceClutch.png" ]; then
    cp "Resources/VoiceClutch.png" "${APP_BUNDLE}/Contents/Resources/VoiceClutch.png"
else
    echo "⚠️  Warning: App icon source file not found (Resources/VoiceClutch.png)"
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
    echo ""
    echo "📦 Production bundle created."
    echo "   The app is ready for distribution."
else
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
