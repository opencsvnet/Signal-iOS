#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_path="${OPENCSV_ARCHIVE_PATH:-$repo_root/build/OpenCSV-Demo.xcarchive}"
export_options="${OPENCSV_EXPORT_OPTIONS:-$repo_root/Config/OpenCSV-TestFlight-ExportOptions.plist}"
export_path="${OPENCSV_EXPORT_PATH:-$repo_root/build/TestFlightExport}"
xcode_path="${OPENCSV_XCODE_PATH:-/Applications/Xcode.app}"

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

export DEVELOPER_DIR="$xcode_path/Contents/Developer"

mkdir -p "$export_path"

xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options" \
    -allowProvisioningUpdates

echo "TestFlight upload submitted from: $archive_path"
