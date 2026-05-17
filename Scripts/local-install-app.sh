#!/usr/bin/env bash
set -euo pipefail

# Builds SonosControl in Release, signs with Developer ID, and swaps it into
# /Applications/SonosControl.app. Uses the same signing identity each time so
# the Designated Requirement is stable across rebuilds — meaning any granted
# permissions (Local Network, etc.) persist.

SCHEME="SonosControl"
DISPLAY_NAME="Sonos Control"
CONFIGURATION="Release"
DERIVED_DATA_PATH="build"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${SCHEME}.app"
INSTALL_PATH="/Applications/${DISPLAY_NAME}.app"
# Legacy install path (before we started installing as "Sonos Control.app").
# Cleaned up automatically below to avoid two copies sitting in /Applications.
LEGACY_INSTALL_PATH="/Applications/${SCHEME}.app"

cd "$(dirname "$0")/.."

SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
if [ -z "${SIGNING_IDENTITY}" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
    | head -n 1)"
fi
if [ -z "${SIGNING_IDENTITY}" ]; then
  echo "No Developer ID Application identity found in the keychain." >&2
  echo "Add one via Xcode → Settings → Accounts → Manage Certificates." >&2
  exit 1
fi
echo "Signing identity: ${SIGNING_IDENTITY}"

remove_signature_if_present() {
  local target="$1"
  if codesign --display --verbose=1 "${target}" >/dev/null 2>&1; then
    codesign --remove-signature "${target}"
  fi
}

BUILD_CMD=(xcodebuild
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  CODE_SIGN_STYLE=Manual
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  build)

echo "Building ${SCHEME} (${CONFIGURATION})…"
if command -v xcbeautify >/dev/null 2>&1; then
  set -o pipefail
  "${BUILD_CMD[@]}" | xcbeautify
else
  "${BUILD_CMD[@]}"
fi

if [ ! -d "${APP_PATH}" ]; then
  echo "Built app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "Signing with Developer ID…"
APP_EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${SCHEME}"
remove_signature_if_present "${APP_EXECUTABLE_PATH}"
codesign --force --options runtime --timestamp \
  --sign "${SIGNING_IDENTITY}" "${APP_EXECUTABLE_PATH}"

remove_signature_if_present "${APP_PATH}"
codesign --force --options runtime --timestamp \
  --sign "${SIGNING_IDENTITY}" "${APP_PATH}"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null

echo "Stopping any running ${SCHEME}…"
pkill -x "${SCHEME}" 2>/dev/null || true

# Remove any prior installs (current and legacy locations).
for path in "${INSTALL_PATH}" "${LEGACY_INSTALL_PATH}"; do
  if [ -e "${path}" ]; then
    echo "Removing old ${path}…"
    if command -v trash >/dev/null 2>&1; then
      trash "${path}"
    else
      rm -rf "${path}"
    fi
  fi
done

echo "Installing to ${INSTALL_PATH}…"
cp -R "${APP_PATH}" "${INSTALL_PATH}"

echo "Launching ${INSTALL_PATH}…"
open "${INSTALL_PATH}"

echo
echo "Installed:"
codesign -dv --verbose=4 "${INSTALL_PATH}" 2>&1 \
  | sed -n 's/^Identifier=/  Identifier: /p; s/^Authority=/  Authority: /p' \
  | head -n 3
