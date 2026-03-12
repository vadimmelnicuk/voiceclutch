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
    echo "🔨 Building VoiceClutch for PRODUCTION (Release configuration)..."
    swift build -c release
else
    echo "🔨 Building VoiceClutch (Debug configuration)..."
    swift build -c debug
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

echo "✅ Build successful!"
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
