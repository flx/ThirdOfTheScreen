#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/build"
APP_NAME="ThirdOfTheScreen.app"
BUILD_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME"
INSTALL_PATH="/Applications/$APP_NAME"
SIGNING_IDENTITY="${THIRD_OF_THE_SCREEN_SIGNING_IDENTITY:-}"
SIGNING_IDENTITY_LABEL="$SIGNING_IDENTITY"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  read -r SIGNING_IDENTITY SIGNING_IDENTITY_LABEL <<<"$(
    security find-identity -p codesigning -v \
      | awk -F'"' '
          /Developer ID Application:/ {
            hash = $1
            sub(/^[[:space:]]*[0-9]+\) /, "", hash)
            sub(/[[:space:]]+$/, "", hash)
            print hash, $2
            exit
          }
        '
  )"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  read -r SIGNING_IDENTITY SIGNING_IDENTITY_LABEL <<<"$(
    security find-identity -p codesigning -v \
      | awk -F'"' '
          /Apple Development:/ {
            hash = $1
            sub(/^[[:space:]]*[0-9]+\) /, "", hash)
            sub(/[[:space:]]+$/, "", hash)
            print hash, $2
            exit
          }
        '
  )"
fi

xcodebuild \
  -project "$ROOT_DIR/ThirdOfTheScreen.xcodeproj" \
  -scheme ThirdOfTheScreen \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ -e "$INSTALL_PATH" ]]; then
  mv "$INSTALL_PATH" "/tmp/${APP_NAME:r}-previous-$(date +%s).app"
fi

ditto "$BUILD_APP_PATH" "$INSTALL_PATH"
xattr -cr "$INSTALL_PATH"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$INSTALL_PATH"
  echo "Signed with: ${SIGNING_IDENTITY_LABEL:-$SIGNING_IDENTITY}"
else
  echo "No stable signing identity found. Falling back to ad hoc signing, which can break Accessibility approval across rebuilds." >&2
  codesign --force --deep --sign - "$INSTALL_PATH"
fi

codesign --verify --deep --strict "$INSTALL_PATH"

echo "Installed to $INSTALL_PATH"
