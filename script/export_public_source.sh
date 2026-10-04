#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <empty-output-directory>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$1"

if [[ -e "$TARGET_DIR" ]] && [[ ! -d "$TARGET_DIR" || -n "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "refusing to overwrite non-empty directory or file: $TARGET_DIR" >&2
  exit 1
fi

# Export only the committed tree. Local files and uncommitted edits are excluded.
COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
ARCHIVE="$(mktemp /private/tmp/cellar-public-source.XXXXXX)"
trap 'rm -f "$ARCHIVE"' EXIT
git -C "$ROOT_DIR" archive --format=tar --output="$ARCHIVE" "$COMMIT"
if tar -tf "$ARCHIVE" | LC_ALL=C grep -E '(^|/)(AGENTS?\.md|WORKSPACE-STATE\.md|协议|public-release|\.local-backups|xcuserdata)(/|$)' > /dev/null; then
  echo "refusing to export committed local-only files; review the tracked tree" >&2
  exit 1
fi
mkdir -p "$TARGET_DIR"
tar -xf "$ARCHIVE" -C "$TARGET_DIR"
echo "Public source exported from commit $COMMIT to: $TARGET_DIR"
echo "Uncommitted changes and local-only files were not exported."
