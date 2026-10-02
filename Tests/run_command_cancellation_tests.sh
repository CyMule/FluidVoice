#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-command-cancellation.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Compile the entire production agent, including streaming callbacks and recursive turns.
# Only its model, terminal, UI, and UserDefaults dependencies are test doubles.
xcrun swiftc -parse-as-library \
    Sources/Fluid/Services/CommandModeService.swift \
    Sources/Fluid/Persistence/ChatHistoryStore.swift \
    Tests/CommandCancellationTests.swift \
    -o "$task_test_dir/cancellation-tests"
"$task_test_dir/cancellation-tests"
