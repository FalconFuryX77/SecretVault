#!/usr/bin/env bash
# Assembles the public landing page into a folder a static host can serve
# (used by .github/workflows/pages.yml; run it locally to preview).
#
# site/landing.html is the page itself, without the <!doctype>/<html> lines
# (the Claude artifact host adds those); this script adds them, and copies
# the two fonts the page serves itself.
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
cp assets/fonts/Outfit-Variable.ttf assets/fonts/FiraCode-Variable.ttf \
   assets/fonts/Outfit-OFL.txt assets/fonts/FiraCode-OFL.txt "$OUT/fonts/"
echo "built $OUT"
