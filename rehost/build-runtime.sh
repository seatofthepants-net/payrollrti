#!/bin/sh
# Build the native macOS CPython 2.7 runtime that runs HMRC's Linux Basic PAYE Tools bytecode, and
# assemble it into a relocatable directory PayrollRTI embeds as Contents/Resources/LinuxBuildRuntime.
#
# Under $OUT (default ~/Library/PayrollRTI-Linux/build; CPython's Makefile can't take spaces in the prefix):
#   runtime/            the full CPython 2.7.18 install (arm64, UCS-4, static libpython), used only as a build input
#   ext/                HMRC's non-stdlib C extensions rebuilt for arm64, as dotted filenames (cx_Freeze's layout)
#   LinuxBuildRuntime/  what the app ships: bin/python2.7, lib/python2.7 (trimmed), ext/, rti, manifest.txt
#
# Everything links only against the macOS SDK: OpenSSL 1.1.1 and libjpeg are linked statically, sqlite,
# zlib, bz2, libffi, libxml2 and libxslt come from the system. Versions match the 26.1 Linux payload:
# lxml 4.5.2, Pillow 6.2.2, reportlab 3.5.0 (pure Python; its accelerators are unused by BPT),
# scandir 1.10.0, 4Suite-XML 1.0.2. Python 2.7.18 is the version HMRC froze.
#
# Needs: Xcode Command Line Tools, Homebrew openssl@1.1 and jpeg-turbo (static libraries only).
set -eu

OUT=${OUT:-"$HOME/Library/PayrollRTI-Linux/build"}
case "$OUT" in *" "*) echo "OUT must not contain spaces: $OUT" >&2; exit 2;; esac
SRC="$OUT/src"
RUNTIME="$OUT/runtime"
EXT="$OUT/ext"
BUNDLE="$OUT/LinuxBuildRuntime"
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK=$(xcrun --show-sdk-path)
BREW=/opt/homebrew/opt
JOBS=$(sysctl -n hw.ncpu)

mkdir -p "$SRC" "$EXT"
cd "$SRC"

fetch() { [ -f "$2" ] || curl -fsSL -o "$2" "$1"; }

# Link directories holding only static archives, so `-lssl` and `-ljpeg` can't pick up a Homebrew dylib.
STATIC="$OUT/static-libs"
mkdir -p "$STATIC"
ln -sf "$BREW/openssl@1.1/lib/libssl.a" "$BREW/openssl@1.1/lib/libcrypto.a" "$BREW/jpeg-turbo/lib/libjpeg.a" "$STATIC/"

# ---- CPython 2.7.18 with pyenv's Apple Silicon patches --------------------------------------------
PYENV_PATCHES=https://raw.githubusercontent.com/pyenv/pyenv/master/plugins/python-build/share/python-build/patches/2.7.18/Python-2.7.18
for p in 0001-Detect-arm64-in-configure 0002-Fix-macOS-_tkinter-use-of-Tck-Tk-in-Library-Framewor \
         0003-Support-arm64-in-Mac-Tools-pythonw 0004-Use-system-libffi-for-Mac-OS-10.15-and-up \
         0005-ctypes-use-the-correct-ABI-for-variadic-functions 0006-ctypes-probe-libffi-for-ffi_closure_alloc-and-ffi_pr \
         0007-Remove-QuickTime-from-link-args; do
  fetch "$PYENV_PATCHES/$p.patch" "$p.patch"
done
fetch https://www.python.org/ftp/python/2.7.18/Python-2.7.18.tgz Python-2.7.18.tgz

if [ ! -x "$RUNTIME/bin/python2.7" ]; then
  rm -rf Python-2.7.18 && tar xzf Python-2.7.18.tgz
  (
    cd Python-2.7.18
    for p in ../*.patch; do patch -p1 -s < "$p"; done
    # -isysroot must be in the Makefile's CFLAGS: setup.py only finds zlib/bz2 headers in the SDK via it.
    export CFLAGS="-isysroot $SDK -Wno-error=implicit-function-declaration -Wno-implicit-function-declaration -I$BREW/openssl@1.1/include"
    export CPPFLAGS="-isysroot $SDK -I$BREW/openssl@1.1/include"
    export LDFLAGS="-L$STATIC"
    ./configure --prefix="$RUNTIME" --enable-unicode=ucs4 --with-ensurepip=install \
      MACOSX_DEPLOYMENT_TARGET=14.0 > configure.log 2>&1
    make -j"$JOBS" > make.log 2>&1
    make install > install.log 2>&1
  )
fi
PY="$RUNTIME/bin/python2.7"
"$PY" -c 'import zlib, bz2, ssl, sqlite3, _scproxy, ctypes, unicodedata, zipimport'

# ---- third-party extension modules, pinned to the payload's versions ----------------------------
export CFLAGS="-isysroot $SDK -Wno-error=implicit-function-declaration"
export LDFLAGS="-L$STATIC"
"$PY" -m pip install -q "lxml==4.5.2" "scandir==1.10.0" --no-binary :all:
"$PY" -m pip install -q --no-deps "reportlab==3.5.0"

[ -f Pillow-6.2.2.tar.gz ] || "$PY" -m pip download -q --no-deps --no-binary :all: "Pillow==6.2.2" -d .
rm -rf Pillow-6.2.2 && tar xzf Pillow-6.2.2.tar.gz
(
  cd Pillow-6.2.2
  # install re-runs build_ext; setup.cfg is the only way the paths reach every invocation.
  cat > setup.cfg <<EOF
[build_ext]
disable-platform-guessing=1
include-dirs=$BREW/jpeg-turbo/include:$SDK/usr/include
library-dirs=$STATIC:$SDK/usr/lib
EOF
  "$PY" -m pip install -q --no-deps . > build.log 2>&1
)
"$PY" -c 'import PIL._imaging, lxml.etree, _scandir, reportlab'

fetch https://files.pythonhosted.org/packages/0e/ae/3c5b4fffb12be7c3a80c99475853349e1cf8477f99051921ea06fbf5e3b9/4Suite-XML-1.0.2.tar.gz 4Suite-XML-1.0.2.tar.gz
rm -rf 4Suite-XML-1.0.2 && tar xzf 4Suite-XML-1.0.2.tar.gz
(
  cd 4Suite-XML-1.0.2
  # Its 2006 build tool scans site-packages metadata and rejects modern Requires-Python specifiers.
  patch -p1 -s < "$HERE/patches/4suite-distext-tolerate-version-specifiers.patch"
  CFLAGS="-isysroot $SDK -Wno-error -w" "$PY" setup.py build > build.log 2>&1
)

# ---- the cx_Freeze-style flat extension directory ----------------------------------------------
rm -f "$EXT"/*.so
for so in $(find 4Suite-XML-1.0.2/build -name '*.so'); do
  rel=${so#*/lib.*/}
  cp "$so" "$EXT/$(echo "$rel" | tr / .)"
done
SP="$RUNTIME/lib/python2.7/site-packages"
cp "$SP/lxml/etree.so" "$EXT/lxml.etree.so"
cp "$SP/lxml/_elementpath.so" "$EXT/lxml._elementpath.so"
cp "$SP/_scandir.so" "$EXT/_scandir.so"
cp "$SP/PIL/_imaging.so" "$EXT/PIL._imaging.so"

# ---- the relocatable bundle the app embeds ------------------------------------------------------
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/bin" "$BUNDLE/lib"
cp "$RUNTIME/bin/python2.7" "$BUNDLE/bin/python2.7"
cp -R "$RUNTIME/lib/python2.7" "$BUNDLE/lib/python2.7"
cp -R "$EXT" "$BUNDLE/ext"
cp "$HERE/rti" "$BUNDLE/rti"
(
  cd "$BUNDLE/lib/python2.7"
  # HMRC's zip carries the Python side of lxml, PIL, reportlab and scandir; our site-packages isn't on sys.path.
  rm -rf test lib-tk idlelib lib2to3 ensurepip distutils site-packages config plat-darwin plat-mac
  find . -name '*.pyo' -delete
  find . -name 'test' -type d -prune -exec rm -rf {} +
  find . -name 'tests' -type d -prune -exec rm -rf {} +
)
# Precompile so nothing ever wants to write into the signed bundle (the launcher also sets dont_write_bytecode).
"$BUNDLE/bin/python2.7" -S -m compileall -q "$BUNDLE/lib/python2.7" > /dev/null

# Every Mach-O must link only against the system; anything pointing at Homebrew would break on another Mac.
bad=$(find "$BUNDLE" -type f \( -name '*.so' -o -path '*/bin/*' \) -exec otool -L {} + \
      | awk '/^[^\t]/ {f=$0} /^\t/ && $1 !~ /^(\/usr\/lib\/|\/System\/)/ {print f ": " $1}')
if [ -n "$bad" ]; then echo "non-system dynamic dependencies:" >&2; echo "$bad" >&2; exit 1; fi

# Module names this runtime provides, which the app checks a new HMRC payload against before installing it.
# The reportlab accelerators have pure-Python fallbacks and BPT doesn't use renderPM, so they count as provided.
{
  echo "# Python extension modules provided by LinuxBuildRuntime, one per line."
  "$BUNDLE/bin/python2.7" -S -c 'import sys; print "\n".join(sorted(sys.builtin_module_names))'
  ls "$BUNDLE/lib/python2.7/lib-dynload" | sed 's/\.so$//'
  ls "$BUNDLE/ext" | sed 's/\.so$//'
  printf 'reportlab.graphics._renderPM\nreportlab.lib._rl_accel\nreportlab.lib.pyHnj\n'
} | sort -u > "$BUNDLE/manifest.txt"
{
  echo "python 2.7.18 $(uname -m) built $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "$BUNDLE/bin/python2.7" -S -c 'import ssl, sqlite3; print ssl.OPENSSL_VERSION; print "sqlite", sqlite3.sqlite_version'
} > "$BUNDLE/VERSION"

echo "bundle: $BUNDLE ($(du -sh "$BUNDLE" | cut -f1), $(ls "$BUNDLE/ext" | wc -l | tr -d ' ') extension modules)"
cat "$BUNDLE/VERSION"
