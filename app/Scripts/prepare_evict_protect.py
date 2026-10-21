"""Recently loaded objects are not force-evicted (GTA-148; Source/NativeStreamingHealth.c pg_may_evict).

rage::strStreamingInfoManager::DeleteNextLeastUsedObject walks the loaded objects from least recently used and
removes the first one its module says is unused, with its dependencies (each checked by IsObjectReadyToDelete).
Under the memory guard's eviction pressure that kept choosing objects loaded moments earlier, which the engine
requested again at once. Both checks also ask pg_may_evict(strIndex): an object loaded in the last few seconds
counts as in use.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
function = fn('rage::strStreamingInfoManager::DeleteNextLeastUsedObject(unsigned int, rage::strStreamingModule*, bool)')
ready = fn('rage::strStreamingInfoManager::IsObjectReadyToDelete(rage::strIndex, unsigned int)')
DECLARATION = 'extern u32 pg_may_evict(u32 index);'
path = next(p for p in sorted((root / 'Generated').glob('game_*.c')) if re.search(rf'^u32 w2c_game_f{function}\(w2c_game\* instance', p.read_text(), re.M))
s = path.read_text()
head = re.search(rf'^u32 w2c_game_f{function}\(w2c_game\* instance[^\n]*\{{$', s, re.M)
start = head.start(); end = s.index('\n}\n', start) + 3
body = s[start:end]
if 'pg_may_evict(' in body:
    print(f'evict protect: f{function} already patched')
else:
    # 1. The candidate (var_l8): its module's "still used" answer, or loaded moments ago.
    old = '    var_i0 = !(var_i0);\n    if (var_i0) {goto var_B4;}\n'
    if body.count(old) != 1 or 'w2c_game_t10, var_j2' not in body:
        raise RuntimeError(f'Pinned f{function} (DeleteNextLeastUsedObject) changed: candidate check not found')
    body = body.replace(old, '    var_i0 = !(var_i0) && pg_may_evict(var_l8);\n    if (var_i0) {goto var_B4;}\n', 1)
    # 2. Each dependency removed with it (var_l8 holds its index for IsObjectReadyToDelete).
    old = f'        var_i0 = w2c_game_f{ready}(instance, var_j0, var_i1, var_i2);\n        if (var_i0) {{'
    if body.count(old) != 1:
        raise RuntimeError(f'Pinned f{function} (DeleteNextLeastUsedObject) changed: dependency check not found')
    body = body.replace(old, f'        var_i0 = w2c_game_f{ready}(instance, var_j0, var_i1, var_i2);\n        var_i0 = var_i0 && pg_may_evict(var_l8);\n        if (var_i0) {{', 1)
    s = s[:start] + body + s[end:]
    if DECLARATION not in s:
        first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
        s = s[:first.end()] + '\n' + DECLARATION + s[first.end():]
    path.write_text(s)
    print(f'evict protect: patched f{function} in {path.name}')
