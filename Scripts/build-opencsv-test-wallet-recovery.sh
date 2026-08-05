#!/bin/bash
# Build the deliberately opt-in DEBUG simulator variant that contains the
# signet/regtest-only OpenCSV device-rebind facility. Normal Debug and every
# Release build omit both the Rust symbol and Swift recovery UI.
set -euo pipefail

signal_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
rust_root="${OPENCSV_LOCAL_RUST_PATH:-$signal_root/../opencsv-rs-signal-recovery-observers}"

if [ ! -f "$rust_root/OpenCsv.podspec" ]; then
    echo "error: OPENCSV_LOCAL_RUST_PATH must name the recovery Rust worktree" >&2
    exit 1
fi

export OPENCSV_LOCAL_RUST_PATH="$rust_root"
export OPENCSV_TEST_WALLET_RECOVERY=1
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    echo "error: DEVELOPER_DIR does not contain a usable Xcode installation: $DEVELOPER_DIR" >&2
    exit 1
fi

cd "$signal_root"
if bundle _2.6.9_ --version >/dev/null 2>&1; then
    bundle _2.6.9_ exec pod install
else
    # Homebrew CocoaPods is an acceptable fallback on development machines
    # that do not have Signal's exact Bundler version installed.
    pod install
fi

derived_data="${OPENCSV_DERIVED_DATA_PATH:-$signal_root/build/OpenCsvRecoveryDerivedData}"
destination="${OPENCSV_SIMULATOR_DESTINATION:-generic/platform=iOS Simulator}"

xcodebuild \
    -quiet \
    -workspace Signal.xcworkspace \
    -scheme Signal \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG OPENCSV_TEST_WALLET_RECOVERY' \
    'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) DEBUG=1 OPENCSV_TEST_WALLET_RECOVERY=1' \
    'OTHER_CFLAGS=$(inherited) -DOPENCSV_TEST_WALLET_RECOVERY=1' \
    build

echo ">> recovery build: $derived_data/Build/Products/Debug-iphonesimulator/Signal.app"
