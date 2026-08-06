#!/bin/bash
# Build the deliberately opt-in DEBUG simulator variant that contains the
# signet/regtest-only OpenCSV device-rebind facility. Normal Debug and every
# Release build omit both the Rust symbol and Swift recovery UI.
set -euo pipefail

signal_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
rust_root="${OPENCSV_LOCAL_RUST_PATH:-$signal_root/../opencsv-rs-signal-recovery-observers}"
lock_backup="$(mktemp)"
manifest_backup="$(mktemp)"

cp "$signal_root/Podfile.lock" "$lock_backup"
if [ -f "$signal_root/Pods/Manifest.lock" ]; then
    cp "$signal_root/Pods/Manifest.lock" "$manifest_backup"
fi
restore_locks() {
    cp "$lock_backup" "$signal_root/Podfile.lock"
    if [ -s "$manifest_backup" ]; then
        cp "$manifest_backup" "$signal_root/Pods/Manifest.lock"
    fi
    rm -f "$lock_backup" "$manifest_backup"
}
trap restore_locks EXIT

if [ ! -f "$rust_root/OpenCsv.podspec" ]; then
    echo "error: OPENCSV_LOCAL_RUST_PATH must name the recovery Rust worktree" >&2
    exit 1
fi

export OPENCSV_LOCAL_RUST_PATH="$rust_root"
export OPENCSV_TEST_WALLET_RECOVERY=1
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Signal's hosted workflow names the Xcode application bundle, while Xcode's
# command-line tools expect DEVELOPER_DIR to name its Contents/Developer
# directory. Accept both forms so the recovery gate matches the main job.
if [ -d "$DEVELOPER_DIR/Contents/Developer" ]; then
    export DEVELOPER_DIR="$DEVELOPER_DIR/Contents/Developer"
fi

if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    echo "error: DEVELOPER_DIR does not contain a usable Xcode installation: $DEVELOPER_DIR" >&2
    exit 1
fi

cd "$signal_root"
rust_revision="$(git -C "$rust_root" rev-parse HEAD)"
OPENCSV_TEST_WALLET_RECOVERY=1 \
    OPENCSV_BUILD_SOURCE_ID="test-wallet-recovery:$rust_revision:clean" \
    sh "$rust_root/apple/build-xcframework.sh" "$rust_root"
if bundle _2.6.9_ --version >/dev/null 2>&1; then
    bundle _2.6.9_ exec pod install
else
    # Homebrew CocoaPods is an acceptable fallback on development machines
    # that do not have Signal's exact Bundler version installed.
    pod install
fi

recovery_archive="$rust_root/OpenCsv.xcframework/ios-arm64_x86_64-simulator/libopencsv_ffi.a"
symbol_receipt="$(mktemp)"
strings "$recovery_archive" > "$symbol_receipt"
if ! grep -Fq opencsv_account_rebind_test_device "$symbol_receipt"; then
    rm -f "$symbol_receipt"
    echo "error: recovery framework omitted opencsv_account_rebind_test_device" >&2
    exit 1
fi
rm -f "$symbol_receipt"

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
    'GCC_TREAT_WARNINGS_AS_ERRORS=YES' \
    'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES' \
    build

echo ">> recovery build: $derived_data/Build/Products/Debug-iphonesimulator/Signal.app"

# Leave subsequent normal Xcode builds pointed at an exact-source default
# framework. The already-linked recovery app above is unchanged.
OPENCSV_TEST_WALLET_RECOVERY=0 \
    OPENCSV_BUILD_SOURCE_ID="default:$rust_revision:clean" \
    sh "$rust_root/apple/build-xcframework.sh" "$rust_root"
