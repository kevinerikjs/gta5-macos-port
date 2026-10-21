"""Add-on cars whose texture parent isn't in this game version (GTA-151; Source/EngineHost.c pg_txd_parent).

A pack's vehicles.meta can name a parent texture set from a later PC update (cbr1000rrr: "vehicles_race_generic").
CMapFileMgr::SetupTxdParent then makes an empty slot for it (fwTxdStore::AddDummySlot), which a later pack may still
fill. When the car is requested, rage::fwTxdStore::GetDependencies returns that parent; with no file behind it the
request fails and the spawn waits 30 s and gives up. GetDependencies now hands the parent to pg_txd_parent first, which
answers with vehshare when the parent has no file in the game's archives by then.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
function = fn('rage::fwTxdStore::GetDependencies(rage::strLocalIndex, rage::strIndex*, int) const')
DECLARATION = 'extern u32 pg_txd_parent(w2c_game* instance, u64 store, u64 def, u32 child, u32 parent);'
path = next(p for p in sorted((root / 'Generated').glob('game_*.c')) if re.search(rf'^u32 w2c_game_f{function}\(w2c_game\* instance', p.read_text(), re.M))
s = path.read_text()
head = re.search(rf'^u32 w2c_game_f{function}\(w2c_game\* instance[^\n]*\{{$', s, re.M)
start = head.start(); end = s.index('\n}\n', start) + 3
body = s[start:end]
if 'pg_txd_parent(' in body:
    print(f'txd parent: f{function} already patched')
else:
    # The slot's parent (fwTxdDef +16, -1 for none), read once at the top; var_j0 is the slot, var_p1 still the child.
    old = ('  var_i0 = i32_load_shared(wasm_rt_local_memory_base, wasm_rt_local_memory_size, instance->w2c_env_memory, '
           '(u64)checked_add_u64(var_j0, 16u));\n  var_p1 = var_i0;\n')
    if body.count(old) != 1:
        raise RuntimeError(f'Pinned f{function} (fwTxdStore::GetDependencies) changed: parent read not found')
    body = body.replace(old, old.replace('  var_p1 = var_i0;\n', '  var_i0 = pg_txd_parent(instance, var_p0, var_j0, var_p1, var_i0);\n  var_p1 = var_i0;\n'), 1)
    s = s[:start] + body + s[end:]
    if DECLARATION not in s:
        first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
        s = s[:first.end()] + '\n' + DECLARATION + s[first.end():]
    path.write_text(s)
    print(f'txd parent: patched f{function} in {path.name}')
