#!/bin/sh
# Renders demo screenshots: sh scripts/snapshot.sh <output-prefix> [scene] [light|dark] [WIDTHxHEIGHT] [scroll-from-top]
# MIRROR_GALLERY=<phase> picks the state shown by the "gallery" scene.
set -eu
cd "$(dirname "$0")/.."
OUT=$1; SCENE=${2:-chat}; LOOK=${3:-light}; SIZE=${4:-1160x760}; SCROLL=${5:-}
rm -f "$OUT"-*.png
open -n -W --env MIRROR_SNAPSHOT="$OUT" --env MIRROR_SCENE="$SCENE" --env MIRROR_APPEARANCE="$LOOK" --env MIRROR_WINDOW="$SIZE" --env MIRROR_SETTINGS_SECTION="${MIRROR_SETTINGS_SECTION:-}" \
    ${SCROLL:+--env MIRROR_SCROLL="$SCROLL"} ${MIRROR_GALLERY:+--env MIRROR_GALLERY="$MIRROR_GALLERY"} dist/TetherDemo.app
ls "$OUT"-*.png
