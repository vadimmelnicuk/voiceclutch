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
    "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
fi
