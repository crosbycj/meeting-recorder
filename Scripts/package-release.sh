#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
temporary_root=$(mktemp -d /tmp/meeting-recorder-release.XXXXXX)
derived_data_dir="$temporary_root/DerivedData"
package_cache_dir=${MEETING_RECORDER_PACKAGE_CACHE:-"$temporary_root/SourcePackages"}

cleanup() {
    rm -rf "$temporary_root"
}
trap cleanup EXIT

cd "$project_dir"

DEVELOPER_DIR="$developer_dir" xcodebuild \
    -project MeetingRecorder.xcodeproj \
    -scheme MeetingRecorder \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$derived_data_dir" \
    -clonedSourcePackagesDirPath "$package_cache_dir" \
    CODE_SIGNING_ALLOWED=NO \
    build

app_path="$derived_data_dir/Build/Products/Release/MeetingRecorder.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
archive_name="Meeting-Recorder-${version}-arm64.zip"
archive_path="$project_dir/dist/$archive_name"

mkdir -p "$project_dir/dist"
rm -f "$archive_path"

# Give the downloadable build an internally consistent ad-hoc signature. This
# is not a Developer ID signature and does not replace Apple notarization.
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"

echo "$archive_path"
