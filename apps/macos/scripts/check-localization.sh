#!/usr/bin/env bash
#
# Fails when Chinese text appears outside the localization table.
#
# Every user-facing string lives in
# `Sources/Meter/Localization/Localization.swift` as a `Copy` entry that carries
# both languages; anything hard-coded elsewhere stays Chinese after the user
# switches to English. Comments are ignored, so the Chinese notes kept in the
# source do not trip the check.
#
# Usage: apps/macos/scripts/check-localization.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$MACOS_DIR/Sources/Meter"
TABLE="Localization/Localization.swift"

status=0
while IFS= read -r file; do
  rel="${file#"$SRC"/}"
  [[ "$rel" == "$TABLE" ]] && continue
  # Strip the `//` comment, then report any Han character left on the line.
  hits="$(perl -CSD -ne 's{//.*$}{}; print "$.:$_" if /\p{Han}/' "$file")"
  if [[ -n "$hits" ]]; then
    echo "error: Chinese text outside $TABLE — $rel" >&2
    echo "$hits" >&2
    status=1
  fi
done < <(find "$SRC" -name '*.swift' | sort)

if [[ "$status" -ne 0 ]]; then
  echo >&2
  echo "Add the string to Copy in Localization.swift and read it from there." >&2
  exit 1
fi

echo "ok: no Chinese text outside the localization table"
