#!/bin/bash
# Run the VoiceClutch test suite.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./test.sh [--swift]

Run the project test suite.
By default the script uses swift to execute:

  swift test

Pass --swift to run directly with swift (same as default):

  swift test

Pass --bun to execute via bun's test script without recursion.

  ./test.sh --bun
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

start=$(date +%s)
echo "🧪 Running VoiceClutch tests..."

if [[ "${1:-}" == "--swift" ]]; then
    shift
    swift test "$@"
elif [[ "${1:-}" == "--bun" ]]; then
    # Avoid recursive invocation when this script itself is bun's test entrypoint.
    shift

    if [[ -n "${VOICECLUTCH_TEST_FROM_BUN:-}" ]]; then
        swift test "$@"
    else
        VOICECLUTCH_TEST_FROM_BUN=1 bun run test "$@"
    fi
else
    swift test "$@"
fi

elapsed=$(( $(date +%s) - start ))
echo "✅ Tests completed in ${elapsed}s"
