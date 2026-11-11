#!/bin/sh
# Renders demo screenshots: sh scripts/snapshot.sh <output-prefix> [scene] [light|dark] [WIDTHxHEIGHT]
set -eu
cd "$(dirname "$0")/.."
OUT=$1; SCENE=${2:-chat}; LOOK=${3:-light}; SIZE=${4:-1160x760}
rm -f "$OUT"-*.png
open -n -W --env MIRROR_SNAPSHOT="$OUT" --env MIRROR_SCENE="$SCENE" --env MIRROR_APPEARANCE="$LOOK" --env MIRROR_WINDOW="$SIZE" --env MIRROR_SETTINGS_SECTION="${MIRROR_SETTINGS_SECTION:-}" dist/ClaudeMirrorDemo.app
ls "$OUT"-*.png
