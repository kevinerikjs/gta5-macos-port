#!/usr/bin/env python3
"""Build Blink (ISC, Justine Tunney) for the app: the x86-64 interpreter that runs Script Hook V mods (.asi).

Vendor/blink is upstream commit Vendor/blink/UPSTREAM-COMMIT.txt (blink/ sources, config.h from
./configure --disable-jit --disable-threads --disable-sockets --disable-fork --disable-overlays
--disable-vfs --disable-ancillary --disable-metal), with these port changes, each marked
"GTA V iOS port" in the source:
- tunables.h: guest addresses are engine (wasm) addresses (kSkew is the engine memory base).
- machine.h: ToHost sends addresses outside engine memory to a scratch page; bigger decode cache.
- memory.c: no page tables: every guest page is engine memory.
- syscall.c: `syscall` from a mod's import stubs goes to Source/NativeASI.c; clock_settime off on iOS.
- assert.c: names the failed check. config.h: no <sys/random.h> (not in the iOS SDK).

    python3 Scripts/build_blink.py --sdk iphoneos [--sdk iphonesimulator]
writes Tools/blink-lib/<sdk>/libblink.a (the project links Tools/blink-lib/$(PLATFORM_NAME)).
"""
import argparse
import hashlib
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = root / 'Vendor/blink'
TARGETS = {'iphoneos': 'arm64-apple-ios16.0', 'iphonesimulator': 'arm64-apple-ios16.0-simulator',
           'maccatalyst': 'arm64-apple-ios16.0-macabi'}
# Mac Catalyst builds with the macOS SDK, and Xcode names its platform macosx (the library folder).
SDK = {'maccatalyst': 'macosx'}
FLAGS = ['-O3', '-DNDEBUG', '-w', '-D_GNU_SOURCE', f'-I{source}']

parser = argparse.ArgumentParser()
parser.add_argument('--sdk', action='append', choices=list(TARGETS))
sdks = parser.parse_args().sdk or ['iphoneos']

files = sorted((source / 'blink').glob('*.c'))
digest = hashlib.sha256()
for path in sorted(source.rglob('*')):
    if path.is_file(): digest.update(path.name.encode()); digest.update(path.read_bytes())
for sdk in sdks:
    library = root / f'Tools/blink-lib/{SDK.get(sdk, sdk)}/libblink.a'
    stamp = library.with_suffix('.sha256')
    key = digest.hexdigest() + ' ' + ' '.join(FLAGS) + ' ' + TARGETS[sdk]
    if library.exists() and stamp.exists() and stamp.read_text() == key:
        print(f'Blink for {sdk} already built.')
        continue
    objects = root / f'Tools/blink-build/{sdk}'
    objects.mkdir(parents=True, exist_ok=True)
    def compile(path):
        out = objects / (path.stem + '.o')
        subprocess.run(['xcrun', '-sdk', SDK.get(sdk, sdk), 'clang', '-c', '-arch', 'arm64', '-target', TARGETS[sdk], *FLAGS, '-o', str(out), str(path)], check=True)
        return out
    with ThreadPoolExecutor(4) as pool:
        built = list(pool.map(compile, files))
    library.parent.mkdir(parents=True, exist_ok=True)
    library.unlink(missing_ok=True)
    subprocess.run(['xcrun', '-sdk', SDK.get(sdk, sdk), 'ar', 'rcs', str(library), *map(str, built)], check=True)
    stamp.write_text(key)
    print(f'Blink for {sdk}: {library.relative_to(root)} ({len(built)} files)')
