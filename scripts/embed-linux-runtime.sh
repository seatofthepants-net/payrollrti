#!/bin/bash
# Xcode build phase: copies the native runtime for HMRC's Linux build into the app and signs its binaries.
#
# The runtime comes from `rehost/build-runtime.sh` (default output ~/Library/PayrollRTI-Linux/build/LinuxBuildRuntime;
# override with LINUX_RUNTIME_DIR). Without it the app still builds, and the Linux engine shows as unavailable.
#
# Nested executables are not covered by Xcode's signing of the app, and notarisation requires every Mach-O to be
# signed with the same identity and the hardened runtime, so when a real identity is in use each one is signed here.
set -euo pipefail

source="${LINUX_RUNTIME_DIR:-$HOME/Library/PayrollRTI-Linux/build/LinuxBuildRuntime}"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/LinuxBuildRuntime"

if [ ! -x "$source/bin/python2.7" ]; then
  echo "warning: no Linux build runtime at $source; the Linux engine will be unavailable in this build"
  rm -rf "$destination"
  exit 0
fi

mkdir -p "$(dirname "$destination")"
rsync -a --delete "$source/" "$destination/"

identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ "$identity" != "-" ]; then
  echo "Signing LinuxBuildRuntime binaries with $identity"
  find "$destination" -type f \( -name '*.so' -o -path '*/bin/*' \) -print0 \
    | xargs -0 codesign --force --sign "$identity" --options runtime --timestamp
fi
