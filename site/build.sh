#!/usr/bin/env bash
# Assembles the public landing page into a folder a static host can serve
# (used by .github/workflows/pages.yml; run it locally to preview).
#
# site/landing.html is the page itself, without the <!doctype>/<html> lines
# (the Claude artifact host adds those); this script adds them, and copies
# the fonts the page serves itself and the demo video with its poster.
#
# Usage: site/build.sh [output-dir]   (default: _site)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-_site}"
rm -rf "$OUT"
mkdir -p "$OUT/fonts"
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
  cat site/landing.html
} > "$OUT/index.html"
# The demo video: from DEMO_VIDEO if given (a local preview), otherwise the
# latest release's copy. Kept out of the repository; it's 10 MB.
cp site/demo-poster.jpg "$OUT/"
if [ -n "${DEMO_VIDEO:-}" ]; then
  cp "$DEMO_VIDEO" "$OUT/demo.mp4"
else
  curl -fsSL -o "$OUT/demo.mp4" https://github.com/FalconFuryX77/Undertow/releases/latest/download/Undertow-demo.mp4
fi
# The two web fonts, each cut down to Latin and served from the site itself.
# Fira Code (21 KB instead of 260), made with
#   python -m fontTools.subset assets/fonts/FiraCode-Variable.ttf --flavor=woff \
#     --layout-features="" --output-file=site/fonts/FiraCode-Latin.woff \
#     --unicodes="$LATIN"
# Inter (46 KB instead of 880), from InterVariable.ttf of Inter 4.1
# (https://github.com/rsms/inter, docs/font-files), weights 400 to 700, made with
#   python -m fontTools.varLib.instancer InterVariable.ttf wght=400:700 -o Inter-400-700.ttf
#   python -m fontTools.subset Inter-400-700.ttf --flavor=woff \
#     --layout-features=kern,calt,case,ccmp,locl --output-file=site/fonts/Inter-Latin.woff \
#     --unicodes="$LATIN"
# where LATIN is
#   U+0020-007E,U+00A0-00FF,U+2013,U+2014,U+2018,U+2019,U+201C,U+201D,U+2022,U+2026,U+2190-2193,U+2212,U+00D7
cp site/fonts/Inter-Latin.woff site/fonts/Inter-OFL.txt \
   site/fonts/FiraCode-Latin.woff assets/fonts/FiraCode-OFL.txt "$OUT/fonts/"
echo "built $OUT"
