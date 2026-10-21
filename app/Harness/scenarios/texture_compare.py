"""GTA-148: how close each screenshot of a texture_thrash.py drive is to the same moment of a reference drive
(usually the same route without a memory limit). The rail replay puts the car at the same place at the same
time, so the difference is mostly what didn't load: grey ground, missing buildings, bridges, trees.

    python3 texture_compare.py REF[,REF2] LABEL...      (screenshots /tmp/gta-texture-thrash/LABEL-N.png or .jpg)

Per screenshot: mean absolute difference of a small greyscale copy (0-255; the touch controls cancel out), the
closest of the references. Two reference drives compared with each other show the noise (traffic, camera).
"""
import glob, re, sys
from PIL import Image

def shots(label):
    files = glob.glob("/tmp/gta-texture-thrash/%s-[0-9]*.png" % label) + glob.glob("/tmp/gta-texture-thrash/%s-[0-9]*.jpg" % label)
    return sorted(files, key=lambda p: int(re.findall(r"-(\d+)\.(?:png|jpg)$", p)[0]))

def small(path):
    im = Image.open(path).convert("L").resize((70, 152))
    return list(getattr(im, "get_flattened_data", im.getdata)())

def dist(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)

def line(name, values):
    print("%-14s %s   mean %.1f" % (name, " ".join("%3.0f" % v for v in values), sum(values) / max(1, len(values))))

refs = [[small(p) for p in shots(r)] for r in sys.argv[1].split(",")]
if len(refs) > 1: line("reference noise", [dist(a, b) for a, b in zip(refs[0], refs[1])])
for label in sys.argv[2:]:
    line(label, [min(dist(small(p), r[i]) for r in refs if i < len(r)) for i, p in enumerate(shots(label))])
