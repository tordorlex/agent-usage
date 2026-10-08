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
  # Strip the `//` comment, then report any Chinese character left on the line.
  #
  # Deliberately not \p{Han}: in Perl that property means Script_Extensions=Han, which
  # also covers U+00B7 "·" — the separator this app prints inside its own strings — and
  # the answer depends on the Unicode tables shipped with the running perl (newer sets
  # list U+00B7 under scx=Han, older ones do not). That made the check pass locally and
  # fail on CI, while still missing full-width punctuation such as ，！. Explicit CJK
  # code point ranges behave the same everywhere and leave "·" alone.
  hits="$(perl -CSD -ne 's{//.*$}{}; print "$.:$_" if /[\x{2E80}-\x{2EFF}\x{3000}-\x{303F}\x{3040}-\x{30FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}\x{FE30}-\x{FE4F}\x{FF01}-\x{FF60}\x{20000}-\x{2FA1F}]/' "$file")"
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
