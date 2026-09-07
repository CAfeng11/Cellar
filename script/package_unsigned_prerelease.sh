#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Cellar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${CELLAR_UNSIGNED_DERIVED_DATA_PATH:-/private/tmp/CellarUnsignedRelease}"
DIST_DIR="${CELLAR_DIST_DIR:-$ROOT_DIR/dist}"

cd "$ROOT_DIR"
mkdir -p "$DIST_DIR"

xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "build completed without the expected app bundle: $BUILT_APP" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
STAGING_DIR="$(mktemp -d "/private/tmp/cellar-unsigned-${VERSION}.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
FINAL_ZIP="$DIST_DIR/$APP_NAME-macOS-unsigned.zip"
CHECKSUM_FILE="$DIST_DIR/$APP_NAME-macOS-unsigned-SHA256.txt"

if [[ -e "$FINAL_ZIP" || -e "$CHECKSUM_FILE" ]]; then
  echo "refusing to overwrite an existing prerelease artifact in $DIST_DIR" >&2
  exit 1
fi

/usr/bin/ditto "$BUILT_APP" "$STAGED_APP"

if /usr/bin/codesign -dv --verbose=4 "$STAGED_APP" 2>&1 | grep -q '^Authority='; then
  echo "refusing to label a certificate-signed app as unsigned" >&2
  exit 1
fi

/usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$FINAL_ZIP"
/usr/bin/shasum -a 256 "$FINAL_ZIP" > "$CHECKSUM_FILE"

echo "Unsigned prerelease artifacts:"
echo "  $FINAL_ZIP"
echo "  $CHECKSUM_FILE"
echo "This build is not Developer ID signed or notarized and Gatekeeper may block its first launch."
