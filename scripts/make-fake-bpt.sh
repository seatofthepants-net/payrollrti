#!/bin/sh
# Builds a stand-in "Basic PAYE Tools.app" whose rti binary is a tiny Python web server, so PayrollRTI's launch
# flow can be exercised on a Mac without HMRC's software installed.
#
#   scripts/make-fake-bpt.sh /tmp/fakebpt [version]
#   open build/.../PayrollRTI.app --args -bptAppPath "/tmp/fakebpt/Basic PAYE Tools.app"
set -eu

dest="${1:?usage: $0 <directory> [version]}"
version="${2:-26.1.26134.173934}"
app="$dest/Basic PAYE Tools.app"
macos="$app/Contents/Helpers/rti.app/Contents/MacOS"

mkdir -p "$macos"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>test.payrollrti.fake-bpt</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
</dict></plist>
PLIST

cat > "$macos/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>Fake Basic PAYE Tools</title>
<style>
  body { font: 16px -apple-system, sans-serif; margin: 0; background: #f3f2f1; color: #0b0c0c; }
  header { background: #0b0c0c; color: #fff; padding: 14px 24px; font-weight: 700; font-size: 20px; }
  main { padding: 24px; max-width: 720px; }
  button { font: inherit; padding: 8px 14px; margin: 4px 8px 4px 0; background: #00703c; color: #fff; border: 0; }
  .note { background: #fff; border-left: 6px solid #1d70b8; padding: 12px 16px; }
</style>
<header>👑 Basic PAYE Tools (stub)</header>
<main>
  <p class="note">This page is served by a stand-in <code>rti runserver</code>, not HMRC's software.</p>
  <h2>Employer: Example Ltd</h2>
  <p>
    <button onclick="alert('Full Payment Submission sent (not really).')">Send FPS</button>
    <button onclick="document.getElementById('c').textContent = confirm('Delete employee?') ? 'Confirmed' : 'Cancelled'">Confirm dialog</button>
    <button onclick="window.print()">Print payslip</button>
  </p>
  <p id="c"></p>
  <p><label>Import file: <input type="file"></label></p>
  <p><a href="https://www.gov.uk/basic-paye-tools">External link (opens in your browser)</a></p>
</main>
HTML

cat > "$macos/rti" <<'SH'
#!/bin/sh
# Mimics `rti runserver <port>`: forks a child server and waits, like Django's autoreloader does.
[ "$1" = "runserver" ] || { echo "usage: rti runserver <port>" >&2; exit 2; }
echo "Fake rti starting on 127.0.0.1:$2"
/usr/bin/python3 -m http.server "$2" --bind 127.0.0.1 --directory "$(dirname "$0")" &
wait
SH
chmod +x "$macos/rti"
echo "$app"
