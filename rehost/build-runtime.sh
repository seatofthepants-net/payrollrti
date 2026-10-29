#!/bin/sh
# Build the native macOS CPython 2.7 runtime that runs HMRC's Linux Basic PAYE Tools bytecode.
#
# Produces, under $OUT (default build/rehost):
#   runtime/   CPython 2.7.18 (arm64, UCS-4, shared), OpenSSL 1.1.1, sqlite, zlib, bz2, ctypes, _scproxy
#   ext/       the non-stdlib C extension modules HMRC's build ships, as dotted filenames
#              (Ft.Xml.cDomlettec.so, lxml.etree.so, PIL._imaging.so, _scandir.so, ...)
#
# Versions match the 26.1 Linux payload exactly: lxml 4.5.2, Pillow 6.2.2, reportlab 3.5.0 (pure Python,
# its optional accelerators are unused by BPT), scandir 1.10.0, 4Suite-XML 1.0.2. Python 2.7.18 is the
# version HMRC froze (stdlib .pyc in the payload are dated 2020-04-20, the 2.7.18 release).
#
# Needs: Xcode Command Line Tools, Homebrew openssl@1.1, sqlite, jpeg-turbo, freetype, libxml2 (for lxml).
set -eu

OUT=${OUT:-"$(cd "$(dirname "$0")/.." && pwd)/build/rehost"}
SRC="$OUT/src"
RUNTIME="$OUT/runtime"
EXT="$OUT/ext"
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK=$(xcrun --show-sdk-path)
BREW=/opt/homebrew/opt
JOBS=$(sysctl -n hw.ncpu)

mkdir -p "$SRC" "$EXT"
cd "$SRC"

fetch() { [ -f "$2" ] || curl -fsSL -o "$2" "$1"; }

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
    export CFLAGS="-isysroot $SDK -Wno-error=implicit-function-declaration -Wno-implicit-function-declaration -I$BREW/openssl@1.1/include -I$BREW/sqlite/include"
    export CPPFLAGS="-isysroot $SDK -I$BREW/openssl@1.1/include -I$BREW/sqlite/include"
    export LDFLAGS="-L$BREW/openssl@1.1/lib -L$BREW/sqlite/lib"
    ./configure --prefix="$RUNTIME" --enable-unicode=ucs4 --enable-shared --with-ensurepip=install \
      MACOSX_DEPLOYMENT_TARGET=14.0 > configure.log 2>&1
    make -j"$JOBS" > make.log 2>&1
    make install > install.log 2>&1
  )
fi
PY="$RUNTIME/bin/python2.7"
"$PY" -c 'import zlib, bz2, ssl, sqlite3, _scproxy, ctypes, unicodedata, zipimport'

# ---- third-party extension modules, pinned to the payload's versions ----------------------------
export CFLAGS="-isysroot $SDK -Wno-error=implicit-function-declaration"
export LDFLAGS="-L$BREW/freetype/lib -L$BREW/jpeg-turbo/lib"
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
include-dirs=$BREW/jpeg-turbo/include:$BREW/freetype/include/freetype2:$SDK/usr/include
library-dirs=$BREW/jpeg-turbo/lib:$BREW/freetype/lib:$SDK/usr/lib
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

# ---- assemble the cx_Freeze-style flat extension directory -------------------------------------
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

echo "runtime: $RUNTIME"
echo "ext:     $EXT ($(ls "$EXT" | wc -l | tr -d ' ') modules)"
ls "$EXT"
