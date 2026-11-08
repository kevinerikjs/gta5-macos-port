"""Reuse a local Mac app's Metal library for experimental builds.

Metal libraries are GPU programs, separate from the ARM/Intel CPU executable.
Validate shader IDs/stages against the supplied game's index. This does not
prove GPU or renderer-version compatibility; loading/rendering must be tested.
"""
import argparse
import json
import shutil
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--index', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
index = json.loads(args.index.read_text())
reflection = args.source / 'shader-reflection.jsonl'
library = args.source / 'shaders-maccatalyst.metallib'
if not library.is_file():
    raise SystemExit('Missing Mac Metal library.')
with library.open('rb') as stream:
    magic = stream.read(4)
if magic != b'MTLB':
    raise SystemExit('Missing or invalid Mac Metal library.')
records = [json.loads(line) for line in reflection.read_text().splitlines() if line.strip()]
actual = {r['h']: r['st'] for r in records}
expected = {h: r['stage'] for h, r in index.items()
            if not h.startswith('_') and r.get('ok') and r.get('stage') in ('vs', 'ps', 'cs')}
missing = [h for h, stage in expected.items() if actual.get(h) != stage]
if missing:
    raise SystemExit(f'Prebuilt shaders do not match the game: {len(missing)} missing or different stages.')
out = root / 'GeneratedResources'
out.mkdir(exist_ok=True)
for file in (reflection, library):
    shutil.copyfile(file, out / file.name)
cached_index = root / 'Resources/shader-index.json'
if args.index.resolve() != cached_index.resolve():
    shutil.copyfile(args.index, cached_index)
print(f'Imported Mac shader library: {len(expected)} shader IDs/stages match. GPU compatibility untested.')
