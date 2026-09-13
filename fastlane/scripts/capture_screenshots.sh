#!/usr/bin/env bash
# fastlane/scripts/capture_screenshots.sh
#
# Wraps `xcrun simctl io <device> screenshot`. Boot the target simulator and
# manually navigate the app to the screen you want *before* running this —
# this script only presses the shutter.
#
# Usage:
#   ./capture_screenshots.sh <device-udid> <device-class> <locale> <shot-name>
#
# Example:
#   ./capture_screenshots.sh 1234ABCD-... iPhone-6.9 en-US 01-lists-home

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <device-udid> <device-class> <locale> <shot-name>" >&2
  exit 1
fi

DEVICE_UDID="$1"
DEVICE_CLASS="$2"
LOCALE="$3"
SHOT_NAME="$4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/../screenshots/${LOCALE}/${DEVICE_CLASS}"
mkdir -p "${OUT_DIR}"

OUT_PATH="${OUT_DIR}/${SHOT_NAME}.png"
xcrun simctl io "${DEVICE_UDID}" screenshot "${OUT_PATH}"
echo "Wrote ${OUT_PATH}"
sips -g pixelWidth -g pixelHeight "${OUT_PATH}"
