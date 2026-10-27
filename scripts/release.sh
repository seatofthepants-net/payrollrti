#!/bin/bash
# Builds a universal PayrollRTI.app, signs it with Developer ID, packages a drag-to-Applications DMG,
# notarises and staples it. Used by .github/workflows/release.yml; also runs locally.
#
#   scripts/release.sh <version> [build-number]
#
# Environment:
#   SIGN=0                     build an unsigned (ad-hoc) DMG for testing; skips notarisation
#   SIGNING_IDENTITY           defaults to "Developer ID Application" (team 632444ASFF)
#   NOTARY_KEY_PATH            path to the App Store Connect API key (.p8)
#   NOTARY_KEY_ID              its key ID
#   NOTARY_ISSUER_ID           its issuer ID
#   SKIP_NOTARIZE=1            sign but don't notarise
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: $0 <version> [build-number]}"
build_number="${2:-1}"
sign="${SIGN:-1}"
identity="${SIGNING_IDENTITY:-Developer ID Application}"
team="632444ASFF"

out="build/release"
archive="$out/PayrollRTI.xcarchive"
app="$out/export/PayrollRTI.app"
dmg="$out/PayrollRTI-$version.dmg"
rm -rf "$out"
mkdir -p "$out"

# Keep CI logs readable when xcbeautify is around; fall back to raw output.
xcbeautify_or_cat() { if command -v xcbeautify >/dev/null; then xcbeautify; else cat; fi; }

echo "==> Archiving PayrollRTI $version ($build_number), universal"
common=(
  -project PayrollRTI.xcodeproj -scheme PayrollRTI -configuration Release
  -destination "generic/platform=macOS" -archivePath "$archive"
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number"
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
)
if [ "$sign" = 1 ]; then
  xcodebuild archive "${common[@]}" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" | xcbeautify_or_cat
else
  xcodebuild archive "${common[@]}" CODE_SIGN_IDENTITY=- | xcbeautify_or_cat
fi

echo "==> Exporting app"
if [ "$sign" = 1 ]; then
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" \
    -exportOptionsPlist scripts/ExportOptions.plist | xcbeautify_or_cat
else
  mkdir -p "$out/export"
  ditto "$archive/Products/Applications/PayrollRTI.app" "$app"
fi

echo "==> Verifying"
archs="$(lipo -archs "$app/Contents/MacOS/PayrollRTI")"
echo "Architectures: $archs"
case "$archs" in *x86_64*arm64* | *arm64*x86_64*) ;; *) echo "error: not a universal binary" >&2; exit 1 ;; esac
codesign --verify --deep --strict --verbose=2 "$app"
if [ "$sign" = 1 ]; then
  codesign --display --verbose=2 "$app" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" >/dev/null \
    || { echo "error: app is not Developer ID signed with hardened runtime" >&2; exit 1; }
fi

echo "==> Building DMG"
staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/PayrollRTI.app"
dmg_args=(
  --volname "PayrollRTI"
  --volicon "$app/Contents/Resources/AppIcon.icns"
  --background design/dmg-background.tiff
  --window-pos 200 120 --window-size 660 400
  --icon-size 128 --text-size 13
  --icon "PayrollRTI.app" 170 200
  --hide-extension "PayrollRTI.app"
  --app-drop-link 490 200
  --no-internet-enable
)
[ "${CREATE_DMG_SKIP_FINDER:-0}" = 1 ] && dmg_args+=(--skip-jenkins)
[ "$sign" = 1 ] && dmg_args+=(--codesign "$identity")
create-dmg "${dmg_args[@]}" "$dmg" "$staging"

if [ "$sign" = 1 ] && [ "${SKIP_NOTARIZE:-0}" != 1 ]; then
  echo "==> Notarising"
  : "${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH}" "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
  xcrun notarytool submit "$dmg" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 30m --output-format json | tee "$out/notarization.json"
  grep -q '"status" *: *"Accepted"' "$out/notarization.json" || {
    id="$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$out/notarization.json" | head -1)"
    [ -n "$id" ] && xcrun notarytool log "$id" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
    echo "error: notarisation failed" >&2
    exit 1
  }
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

shasum -a 256 "$dmg" | sed "s|$out/||" > "$dmg.sha256"
echo "==> Done: $dmg"
