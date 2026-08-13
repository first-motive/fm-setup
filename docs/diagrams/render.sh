#!/usr/bin/env bash
#
# Render every diagram to its SVG sidecar. Commit both: the .d2 is the source
# of truth, the .svg is what a reader sees.
set -euo pipefail
cd "$(dirname "$0")"

FONT_FLAGS=(
  --font-regular fonts/GeistMono-VF.ttf
  --font-bold fonts/GeistMono-VF.ttf
  --font-italic fonts/GeistMono-VF.ttf
)

for f in *.d2; do
  [ "$f" = "styles.d2" ] && continue # style import, not a diagram
  d2 --layout elk "${FONT_FLAGS[@]}" "$f" "${f%.d2}.svg"
done
