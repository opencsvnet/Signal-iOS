#!/usr/bin/env bash
# Copyright 2026 OpenCSV contributors
# SPDX-License-Identifier: AGPL-3.0-only

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
xcode_path="${OPENCSV_XCODE_PATH:-/Applications/Xcode.app}"
team_id="${OPENCSV_APPLE_TEAM_ID:-2858MX5336}"
bundle_prefix="${OPENCSV_BUNDLE_PREFIX:-net.ultravie}"
marketing_version="${OPENCSV_MARKETING_VERSION:-0.1.0}"
build_number="${OPENCSV_BUILD_NUMBER:-}"
archive_path="${OPENCSV_ARCHIVE_PATH:-$repo_root/build/OpenCSV-Demo.xcarchive}"

if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "Set OPENCSV_BUILD_NUMBER to the next positive App Store Connect build number" >&2
    exit 1
fi

if [[ ! -d "$xcode_path" ]]; then
    echo "Xcode not found at $xcode_path" >&2
    exit 1
fi

export DEVELOPER_DIR="$xcode_path/Contents/Developer"

cd "$repo_root"

source_commit="$(git rev-parse --verify HEAD)"
if [[ ! "$source_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Could not resolve an exact 40-character source commit" >&2
    exit 1
fi

# A signed source receipt is meaningful only when the archived source equals
# HEAD. CocoaPods is generated build state and is excluded deliberately; all
# other tracked, staged, or untracked source drift fails closed.
if ! git diff --quiet -- . ':(exclude)Pods' \
    || ! git diff --cached --quiet -- . ':(exclude)Pods' \
    || [[ -n "$(git ls-files --others --exclude-standard -- . ':(exclude)Pods')" ]]; then
    echo "Refusing to archive a dirty source checkout (generated Pods excluded)" >&2
    exit 1
fi

xcodebuild archive \
    -workspace Signal.xcworkspace \
    -scheme Signal \
    -configuration "App Store Release" \
    -destination "generic/platform=iOS" \
    -archivePath "$archive_path" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Automatic \
    SIGNAL_BUNDLEID_PREFIX="$bundle_prefix" \
    ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS=NO \
    ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES= \
    OPENCSV_APP_DISPLAY_NAME="OpenCSV Demo" \
    OPENCSV_APP_MARKETING_VERSION="$marketing_version" \
    OPENCSV_APP_BUILD_NUMBER="$build_number" \
    OPENCSV_SOURCE_COMMIT="$source_commit" \
    OPENCSV_DISTRIBUTION_NETWORK="signet" \
    OPENCSV_PRODUCT_DEPLOYMENT="opencsv-test-usd-v2"

app_path="$archive_path/Products/Applications/Signal.app"
if [[ ! -d "$app_path" ]]; then
    echo "Archive did not contain $app_path" >&2
    exit 1
fi

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
actual_display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app_path/Info.plist")"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Info.plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Info.plist")"
actual_source_commit="$(/usr/libexec/PlistBuddy -c 'Print :OpenCSVSourceCommit' "$app_path/Info.plist")"
actual_network="$(/usr/libexec/PlistBuddy -c 'Print :OpenCSVDistributionNetwork' "$app_path/Info.plist")"
actual_deployment="$(/usr/libexec/PlistBuddy -c 'Print :OpenCSVProductDeployment' "$app_path/Info.plist")"

test "$actual_bundle_id" = "$bundle_prefix.signal"
test "$actual_display_name" = "OpenCSV Demo"
test "$actual_version" = "$marketing_version"
test "$actual_build" = "$build_number"
test "$actual_source_commit" = "$source_commit"
test "$actual_network" = "signet"
test "$actual_deployment" = "opencsv-test-usd-v2"

echo "Archive ready: $archive_path"
echo "Bundle: $actual_bundle_id"
echo "Version: $actual_version ($actual_build)"
echo "Source commit: $actual_source_commit"
echo "Network: $actual_network"
echo "Product deployment: $actual_deployment"
