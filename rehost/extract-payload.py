#!/usr/bin/env python3
"""Turn HMRC's Linux Basic PAYE Tools zip into a payload directory the `rti` launcher can run.

    extract-payload.py payetools-rti-<version>-linux.zip <store dir>

Layers: zip -> AppImage (ELF with a gzip squashfs appended after the last section) -> usr/bptserver.
Only the Python payload is taken; the x86_64 .so files are replaced by the arm64 ones from build-runtime.sh.

The result mirrors the layout of HMRC's own Mac build, because settings_central.py computes paths on
darwin as if it were inside `Helpers/rti.app/Contents/MacOS`:

    <store>/<version>/
        bptserver/                  usr/bptserver minus the .so files
        django -> bptserver/django  INSTALL_DIR/django/core/management/commands is listed from disk
        rti.app/Contents/MacOS -> ../../bptserver     BPT_BASE_PATH; INSTALL_DIR is three levels up

Needs: pip install PySquashfsImage
"""
import os
import re
import struct
import sys
import zipfile

from PySquashfsImage import SquashFsImage


def squashfs_offset(appimage):
    with open(appimage, 'rb') as f:
        header = f.read(64)
        if header[:4] != b'\x7fELF' or header[8:11] != b'AI\x02':
            raise SystemExit('not a type 2 AppImage')
        shoff = struct.unpack('<Q', header[0x28:0x30])[0]
        shentsize, shnum = struct.unpack('<HH', header[0x3a:0x3e])
        f.seek(shoff)
        sections = f.read(shentsize * shnum)
    end = shoff + shentsize * shnum
    for i in range(shnum):
        entry = sections[i * shentsize:(i + 1) * shentsize]
        offset, size = struct.unpack('<QQ', entry[0x18:0x28])
        end = max(end, offset + size)
    with open(appimage, 'rb') as f:
        f.seek(end)
        if f.read(4) != b'hsqs':
            raise SystemExit('no squashfs at offset %d' % end)
    return end


def main(zip_path, store):
    with zipfile.ZipFile(zip_path) as z:
        appimages = [n for n in z.namelist() if n.endswith('.AppImage')]
        if len(appimages) != 1:
            raise SystemExit('expected one AppImage in the zip, found %r' % appimages)
        version = re.search(r'(\d+\.\d+\.\d+\.\d+)', appimages[0])
        if not version:
            raise SystemExit('no version in AppImage name %r' % appimages[0])
        version = version.group(1)
        root = os.path.join(store, version)
        server = os.path.join(root, 'bptserver')
        if os.path.exists(root):
            raise SystemExit('%s already exists' % root)
        appimage = z.extract(appimages[0], os.path.join(store, 'tmp-%s' % version))

    image = SquashFsImage.from_file(appimage, offset=squashfs_offset(appimage))
    prefix = '/usr/bptserver/'
    copied = skipped = 0
    skipped_names = []
    for entry in image:
        if not entry.path.startswith(prefix):
            continue
        rel = entry.path[len(prefix):]
        out = os.path.join(server, rel)
        if entry.is_dir:
            os.makedirs(out, exist_ok=True)
        elif entry.is_file:
            if rel.endswith('.so') or '.so.' in rel:
                skipped += 1
                skipped_names.append(rel)
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, 'wb') as f:
                f.write(entry.read_bytes())
            copied += 1
    os.remove(appimage)
    os.rmdir(os.path.dirname(appimage))

    os.symlink('bptserver/django', os.path.join(root, 'django'))
    os.makedirs(os.path.join(root, 'rti.app', 'Contents'))
    os.symlink('../../bptserver', os.path.join(root, 'rti.app', 'Contents', 'MacOS'))

    with open(os.path.join(root, 'linux-extensions.txt'), 'w') as f:
        f.write('\n'.join(sorted(skipped_names)) + '\n')

    print('%s: %d files, %d x86_64 .so skipped (listed in linux-extensions.txt)' % (root, copied, skipped))
    print('BPT_REHOST_PAYLOAD=%s' % os.path.join(root, 'rti.app', 'Contents', 'MacOS'))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
