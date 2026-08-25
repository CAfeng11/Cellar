#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <empty-output-directory>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$1"

if [[ -e "$TARGET_DIR" ]] && [[ -n "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "refusing to overwrite non-empty directory: $TARGET_DIR" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

/usr/bin/rsync -a \
  --exclude '.git/' \
  --exclude '协议/' \
  --exclude 'public-release/' \
  --exclude 'xcuserdata/' \
  --exclude '*.xcuserstate' \
  --exclude '.DS_Store' \
  "$ROOT_DIR/" "$TARGET_DIR/"

echo "Public source snapshot created at: $TARGET_DIR"
