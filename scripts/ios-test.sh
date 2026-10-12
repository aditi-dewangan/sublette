#!/usr/bin/env bash
# Generates the Xcode project, builds the iPhone app and runs its unit tests on
# an iPhone simulator this Mac has. Used by `make ios-test` and by CI.
set -euo pipefail

cd "$(dirname "$0")/../ios"

xcodegen generate

SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)

DEVICE_ID=$(xcrun simctl list devices available --json | SDK_VERSION="$SDK_VERSION" /usr/bin/python3 -c '
import json, os, re, sys
sdk = tuple(int(part) for part in os.environ["SDK_VERSION"].split(".")[:2])
found = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    # Not newer than this Xcode can drive, not older than the app supports (iOS 17).
    if version > sdk or version < (17, 0):
        continue
    for device in devices:
        if device["name"].startswith("iPhone"):
            found.append((version, device["udid"]))
            break
if not found:
    sys.exit("No usable iPhone simulator found. Install one in Xcode > Settings > Components.")
print(max(found)[1])
')

set +e
xcodebuild test \
  -project Sublette.xcodeproj \
  -scheme Sublette \
  -destination "id=${DEVICE_ID}" 2>&1 | tee xcodebuild.log
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  # Show compile errors and failing tests on the pull request itself.
  grep -E "error: |: error:|Test Case .* failed|XCTAssert.* failed" xcodebuild.log \
    | sort -u | head -40 | sed 's/^/::error title=iPhone::/'
fi
exit "$status"
