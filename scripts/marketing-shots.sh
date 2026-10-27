#!/bin/bash
# Captures marketing screenshots of a Debug build of PayrollRTI running the Basic PAYE Tools installed in
# /Applications, in light and dark appearance, at 2x (2880x1800 for a 1440x900pt window). Writes to docs/marketing/.
#
# Uses the Debug-only snapshot hooks in DebugSnapshot.swift, so it needs no screen-recording permission and can only
# ever capture PayrollRTI's own window (never the desktop or other apps). SwiftUI forms (Settings) and menus (the
# menu-bar item) can't be captured this way; take those by hand with Cmd-Shift-4, Space.
#
# PRIVACY: only run this against an empty BPT (no employers set up). The script refuses if the database has employers.
set -euo pipefail
cd "$(dirname "$0")/.."

out="docs/marketing"
db="$HOME/HMRC/payetools-rti/sqlite3.db"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -f "$db" ]; then
  employers="$(sqlite3 -readonly "$db" "select count(*) from bptrti_employer;")"
  if [ "$employers" != 0 ]; then
    echo "error: Basic PAYE Tools has $employers employer(s) set up. Refusing to screenshot real payroll data." >&2
    exit 1
  fi
fi

xcodebuild build -project PayrollRTI.xcodeproj -scheme PayrollRTI -configuration Debug \
  -derivedDataPath build/DerivedData -quiet
bin="build/DerivedData/Build/Products/Debug/PayrollRTI.app/Contents/MacOS/PayrollRTI"
size=(-debugWindowSize 1440x900)

quit_app() {
  osascript -e 'tell application id "net.seatofthepants.payrollrti" to quit' >/dev/null
  while pgrep -x PayrollRTI >/dev/null; do sleep 1; done
}

wait_for() { # file, timeout
  local start; start=$(date +%s)
  until [ -e "$1" ]; do
    [ $(( $(date +%s) - start )) -gt "$2" ] && { echo "error: timed out waiting for $1" >&2; quit_app; exit 1; }
    sleep 1
  done
}

# Rounded macOS window corners and a soft shadow on a transparent background.
frame() { # in, out
  local radius=32 w h
  w=$(magick identify -format %w "$1"); h=$(magick identify -format %h "$1")
  magick -size "${w}x${h}" xc:black -fill white -draw "roundrectangle 0,0 $((w - 1)),$((h - 1)) $radius,$radius" \
    "$work/mask.png"
  magick "$1" -alpha off "$work/mask.png" -compose CopyOpacity -composite "PNG32:$work/rounded.png"
  magick "$work/rounded.png" \( +clone -background black -shadow 45x48+0+36 \) +swap \
    -background none -compose Over -layers merge +repage "PNG32:$2"
}

mkdir -p "$out"
for mode in light dark; do
  echo "==> $mode: BPT pages"
  "$bin" "${size[@]}" -debugAppearance "$mode" -debugShotsDir "$work/$mode" -debugSnapshotDir "$work/$mode-states" \
    -debugShotPages "add-employer=/bptrti/employer/addpcd/,calculators=/calculators/" >/dev/null 2>&1 &
  wait_for "$work/$mode/.done" 180
  quit_app
  cp "$work/$mode/main.png" "$out/hero-$mode-flat.png"
  frame "$work/$mode/main.png" "$out/hero-$mode.png"
  cp "$work/$mode/add-employer.png" "$out/add-employer-$mode.png"
  cp "$work/$mode/calculators.png" "$out/calculators-$mode.png"
  cp "$(ls "$work/$mode-states/"*-starting.png | head -1)" "$out/starting-$mode.png"

  echo "==> $mode: not-installed screen"
  "$bin" "${size[@]}" -debugAppearance "$mode" -debugPretendBPTMissing YES \
    -debugSnapshotDir "$work/$mode-missing" >/dev/null 2>&1 &
  until ls "$work/$mode-missing/" 2>/dev/null | grep -q not-installed; do sleep 1; done
  sleep 1
  quit_app
  cp "$work/$mode-missing/"*-not-installed.png "$out/bpt-not-installed-$mode.png"
done

pgrep -x rti >/dev/null && echo "warning: an rti process is still running" >&2
ls -1 "$out"
