#!/usr/bin/env bash
# Redraws the DevOS ADE icon set from portal/brand/AppIcon.icon/Assets/torus-teal.png: portal/portal/appicons.py
# composes every PNG in portal/portal/static/icons/, static/brand/glyph.svg and static/logo.svg with Pillow, and
# writes static/icons/SOURCES: the Pillow version used and the sha256 of the source and of every file written. The
# portal tests compare it with the tree, so a stale or hand-edited icon fails the build. Needs python3 with Pillow
# (pip install Pillow); nothing is downloaded.
set -euo pipefail
cd "$(dirname "$0")"
python3 -c 'import PIL' 2>/dev/null || { echo "render-icons.sh needs Pillow: python3 -m pip install Pillow" >&2; exit 1; }
python3 -m portal.appicons
