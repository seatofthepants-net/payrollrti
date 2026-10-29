# Re-hosting HMRC's Linux build on a native Mac runtime (spike)

If HMRC stop shipping a Mac build, or when Rosetta goes (macOS 28), PayrollRTI needs a way to run Basic
PAYE Tools that doesn't depend on HMRC's x86_64 binaries. This spike proves one: take the **Linux**
build, which is the same Python 2.7 bytecode in a different wrapper, and run it on a CPython 2.7 we build
for arm64 macOS. HMRC's bytes are never modified or redistributed; the user's Mac downloads them from
GOV.UK as it does today.

Background: [Angus Forrest's analysis](https://angusforrest.com/posts/reverse-engineering-hmrc-basic-paye-tools).

## What's in HMRC's Linux build

`payetools-rti-<version>-linux.zip` → one AppImage (ELF + gzip squashfs) → `usr/bptserver/`:

| Part | What it is |
|---|---|
| `rti.linux` | cx_Freeze stub with a zip of 6,866 Python 2.7.18 `.pyc` appended; `__main__` is Django's `execute_from_command_line` |
| `libpython2.7.so.1.0`, 78 `.so` | The runtime and C extensions, x86_64 only. 51 are CPython's own; the rest are 4Suite-XML 1.0.2 (15), lxml 4.5.2 (2), Pillow 6.2.2 (1), reportlab 3.5.0 (3, unused by BPT), scandir (1), OpenSSL 1.1 |
| `sqlite3.db`, `templates/`, `static/`, `django/` | Pre-baked database, templates, static files and schemas, and a loose `django/core/management/commands` tree the frozen build lists command names from |

HMRC's own code checks `sys.platform` in seven modules, all for paths and UI cosmetics. `BPT_BASE_PATH`
and `APPDATA` are their own environment overrides for the payload directory and the user-data root
(`$APPDATA/HMRC/payetools-rti`). `sys.frozen = True` is the only thing their packager detection needs.

## Pieces

- `build-runtime.sh`: builds CPython 2.7.18 (pyenv's Apple Silicon patches, UCS-4 to match HMRC's build,
  OpenSSL 1.1.1) and the third-party extensions at the payload's exact versions, into `build/rehost/`.
  4Suite needs one patch to its 2006 build tool (`patches/`), none to its C code.
- `extract-payload.py`: zip → AppImage → squashfs → `usr/bptserver` minus the `.so` files, laid out the way
  `settings_central.py`'s darwin branch expects (`rti.app/Contents/MacOS` and `django` symlinks).
- `rti`: replaces the cx_Freeze stub. Sets `sys.path = [zip, our stdlib, our lib-dynload]` and a
  `meta_path` finder that resolves `Ft.Xml.cDomlettec` to `ext/Ft.Xml.cDomlettec.so`, exactly as
  cx_Freeze does. All Python comes from HMRC's zip, all C from our build.

```sh
sh rehost/build-runtime.sh                                   # ~5 min
pip3 install PySquashfsImage
python3 rehost/extract-payload.py payetools-rti-26.1.26134.173934-linux.zip build/rehost/store

export BPT_REHOST_PAYLOAD=build/rehost/store/26.1.26134.173934/rti.app/Contents/MacOS
export BPT_REHOST_EXT=build/rehost/ext
export APPDATA=/tmp/bpt-data               # keeps data away from ~/HMRC/payetools-rti
build/rehost/runtime/bin/python2.7 -S rehost/rti startdb
build/rehost/runtime/bin/python2.7 -S rehost/rti runserver 46799 --noreload
```

To run it inside PayrollRTI without code changes, make a stand-in `Basic PAYE Tools.app` whose
`Contents/Helpers/rti.app/Contents/MacOS/rti` is a shell script that exports the three variables and
execs the line above, then `open PayrollRTI.app --args -bptAppPath <stand-in> -port 46798`.

## Results (29 Oct 2026, BPT 26.1.26134.173934, Apple silicon, no Rosetta)

- `rti help`, `startdb` (copies the blank DB, checks migrations, integrity test), `runserver`,
  `autobackup` on quit: all as in HMRC's build.
- PayrollRTI's existing UI against it: home page, add employer wizard, settings.
- A real backup (`RTI-26-1-26134__*.bak`) restored through BPT's own **Restore your data**: pre-restore
  backup, DB swap, migrations, "The restoration was a complete success". Seven tax years browsable,
  Employer Payment Record totals rendered, 94 successful submissions listed, submission XML viewable.
- P60s generated: blank (reportlab) and filled (pyPdf overlay), opened in Preview by HMRC's own
  `open_file` darwin path.
- A live NINO Verification Request sent to HMRC's Gateway (`transaction-engine.tax.service.gov.uk`):
  schematron validation, IRmark, TLS via OpenSSL 1.1.1w, authentication, response polling; status
  Success after 30 s, correlation ID returned. The submission XML carries the same product string as
  HMRC's own Mac build (`26.1.26134.173934_OSE`, vendor 9205).
- Module origins verified: every `.py` from HMRC's zip, every `.so` from `ext/` or our `lib-dynload`.

Behaviour that is identical to HMRC's build and not a re-host defect: the 4Suite catalog warning
(`Share/default.cat` isn't in their zip either) and the 404 for `static/css/print_min.css` (not in their
static tree either).

## Not yet done

- A differential test: the same pay run through HMRC's Mac build under Rosetta and through this,
  diffing the generated FPS XML and database rows, then the FPS sent from one copy only (a second
  send would be a duplicate FPS at HMRC).
- Packaging: a Python.framework inside PayrollRTI.app, a Swift extractor (ELF offset + gzip squashfs,
  zlib only), the `.so`-manifest gate for new HMRC releases, and a `ServerController` backend choice.
- An x86_64 slice for Intel Macs, if HMRC drop their Mac build before those Macs leave service.
