#!/bin/sh
# Renders design/icon.svg into the app icon set and design/dmg-background.svg into the DMG background.
# Needs rsvg-convert (brew install librsvg).
set -eu
cd "$(dirname "$0")/.."

iconset="PayrollRTI/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$iconset"

render() { rsvg-convert -w "$2" -h "$2" design/icon.svg -o "$iconset/$1"; }

images=""
for size in 16 32 128 256 512; do
  double=$((size * 2))
  render "icon_${size}x${size}.png" "$size"
  render "icon_${size}x${size}@2x.png" "$double"
  for scale in 1x 2x; do
    suffix=""; [ "$scale" = 2x ] && suffix="@2x"
    images="$images    { \"filename\" : \"icon_${size}x${size}${suffix}.png\", \"idiom\" : \"mac\", \"scale\" : \"$scale\", \"size\" : \"${size}x${size}\" },
"
  done
done

printf '{\n  "images" : [\n%s  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' \
  "$(printf '%s' "$images" | sed '$ s/,$//')" > "$iconset/Contents.json"

rsvg-convert -w 1024 -h 1024 design/icon.svg -o design/icon-1024.png
rsvg-convert -w 512 -h 512 design/icon.svg -o design/icon-512.png

rsvg-convert -w 660 -h 400 design/dmg-background.svg -o design/dmg-background.png
rsvg-convert -w 1320 -h 800 design/dmg-background.svg -o design/dmg-background@2x.png
tiffutil -cathidpicheck design/dmg-background.png design/dmg-background@2x.png -out design/dmg-background.tiff >/dev/null
echo "Icons written to $iconset"
