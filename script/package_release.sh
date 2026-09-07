#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Cellar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${CELLAR_RELEASE_DERIVED_DATA_PATH:-/private/tmp/CellarRelease}"
DIST_DIR="${CELLAR_DIST_DIR:-$ROOT_DIR/dist}"
SIGNING_IDENTITY="${CELLAR_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${CELLAR_NOTARY_PROFILE:-}"
NOTARY_KEY="${CELLAR_NOTARY_KEY:-}"
NOTARY_KEY_ID="${CELLAR_NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${CELLAR_NOTARY_ISSUER:-}"

usage() {
  cat <<'EOF'
usage: ./script/package_release.sh --identity "Developer ID Application: ..." [notary options]

Signing:
  --identity NAME          Developer ID Application identity in the current keychain

Notarization (choose one):
  --notary-profile NAME    notarytool keychain profile
  --notary-key PATH        App Store Connect API private key (.p8)
  --notary-key-id ID       App Store Connect API key ID
  --notary-issuer ID       App Store Connect API issuer ID

Environment equivalents:
  CELLAR_SIGNING_IDENTITY, CELLAR_NOTARY_PROFILE, CELLAR_NOTARY_KEY,
  CELLAR_NOTARY_KEY_ID, CELLAR_NOTARY_ISSUER, CELLAR_DIST_DIR,
  CELLAR_RELEASE_DERIVED_DATA_PATH
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      SIGNING_IDENTITY="${2:-}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --notary-key)
      NOTARY_KEY="${2:-}"
      shift 2
      ;;
    --notary-key-id)
      NOTARY_KEY_ID="${2:-}"
      shift 2
      ;;
    --notary-issuer)
      NOTARY_ISSUER="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "a Developer ID Application identity is required" >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
  echo "signing identity is not available in the current keychain: $SIGNING_IDENTITY" >&2
  exit 1
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  NOTARY_MODE="profile"
elif [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]]; then
  NOTARY_MODE="api-key"
else
  echo "provide either --notary-profile or the complete App Store Connect API key options" >&2
  exit 1
fi

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
STAGING_DIR="$(mktemp -d "/private/tmp/cellar-release-${VERSION}.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
NOTARY_ZIP="$STAGING_DIR/$APP_NAME-notary.zip"
FINAL_ZIP="$DIST_DIR/$APP_NAME-macOS.zip"
CHECKSUM_FILE="$DIST_DIR/$APP_NAME-macOS-SHA256.txt"

if [[ -e "$FINAL_ZIP" || -e "$CHECKSUM_FILE" ]]; then
  echo "refusing to overwrite an existing release artifact in $DIST_DIR" >&2
  exit 1
fi

/usr/bin/ditto "$BUILT_APP" "$STAGED_APP"
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$STAGED_APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
/usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$NOTARY_ZIP"

if [[ "$NOTARY_MODE" == "profile" ]]; then
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
else
  xcrun notarytool submit "$NOTARY_ZIP" \
    --key "$NOTARY_KEY" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER" \
    --wait
fi

xcrun stapler staple "$STAGED_APP"
xcrun stapler validate "$STAGED_APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$STAGED_APP"

/usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$FINAL_ZIP"
/usr/bin/shasum -a 256 "$FINAL_ZIP" > "$CHECKSUM_FILE"

echo "Release artifacts:"
echo "  $FINAL_ZIP"
echo "  $CHECKSUM_FILE"
