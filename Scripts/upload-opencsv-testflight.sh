#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_path="${OPENCSV_ARCHIVE_PATH:-$repo_root/build/OpenCSV-Demo.xcarchive}"
export_options="${OPENCSV_EXPORT_OPTIONS:-$repo_root/Config/OpenCSV-TestFlight-ExportOptions.plist}"
export_path="${OPENCSV_EXPORT_PATH:-$repo_root/build/TestFlightExport}"
xcode_path="${OPENCSV_XCODE_PATH:-/Applications/Xcode.app}"
bundle_prefix="${OPENCSV_BUNDLE_PREFIX:-net.ultravie}"

if [[ "${OPENCSV_UPLOAD_APPROVED:-}" != "YES" ]]; then
    echo "Refusing to upload without deliberate OPENCSV_UPLOAD_APPROVED=YES" >&2
    exit 1
fi

if [[ ! -d "$archive_path" ]]; then
    echo "Missing archive: $archive_path" >&2
    exit 1
fi

if [[ ! -f "$export_options" ]]; then
    echo "Missing export options: $export_options" >&2
    exit 1
fi

app_path="$archive_path/Products/Applications/Signal.app"
info_plist="$app_path/Info.plist"
if [[ ! -f "$info_plist" ]]; then
    echo "Archive does not contain the expected Signal.app Info.plist" >&2
    exit 1
fi

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
actual_source_commit="$(/usr/libexec/PlistBuddy -c 'Print :OpenCSVSourceCommit' "$info_plist")"
actual_network="$(/usr/libexec/PlistBuddy -c 'Print :OpenCSVDistributionNetwork' "$info_plist")"
actual_deployment="$(/usr/libexec/PlistBuddy -c 'Print :OpenCSVProductDeployment' "$info_plist")"

if [[ "$actual_bundle_id" != "$bundle_prefix.signal" \
    || ! "$actual_build" =~ ^[1-9][0-9]*$ \
    || ! "$actual_source_commit" =~ ^[0-9a-f]{40}$ \
    || "$actual_network" != "signet" \
    || "$actual_deployment" != "opencsv-test-usd-v2" ]]; then
    echo "Refusing to upload an archive without the exact OpenCSV signet release identity" >&2
    exit 1
fi

export DEVELOPER_DIR="$xcode_path/Contents/Developer"

mkdir -p "$export_path"

xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options" \
    -allowProvisioningUpdates

echo "TestFlight upload submitted from: $archive_path"
echo "Build: $actual_build"
echo "Source commit: $actual_source_commit"
echo "Network: $actual_network"
echo "Product deployment: $actual_deployment"
