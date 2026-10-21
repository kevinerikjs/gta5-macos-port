"""Mesh release (GTA-152; Source/NativeMeshRelease.c pg_mesh_source).

wasm_null_d3d::NullDevice::CreateBuffer copies a new buffer's initial data into the command ring in chunks of up
to 4 MB. After the last chunk it now tells the host which engine memory that data came from (object id, source
address, size, and the D3D11_BUFFER_DESC), so the renderer can hand the engine's copy of a mesh back to iOS once
the Metal buffer holds it. The call does nothing unless PG_MESH_RELEASE=1.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
function = fn('wasm_null_d3d::NullDevice::CreateBuffer(D3D11_BUFFER_DESC const*, D3D11_SUBRESOURCE_DATA const*, ID3D11Buffer**)')
DECLARATION = 'extern void pg_mesh_source(u32 oid, u64 src, u32 size, u64 desc);'
path = next(p for p in sorted((root / 'Generated').glob('game_*.c')) if re.search(rf'^u32 w2c_game_f{function}\(w2c_game\* instance', p.read_text(), re.M))
s = path.read_text()
head = re.search(rf'^u32 w2c_game_f{function}\(w2c_game\* instance[^\n]*\{{$', s, re.M)
start = head.start(); end = s.index('\n}\n', start) + 3
body = s[start:end]
if 'pg_mesh_source(' in body:
    print(f'mesh release: f{function} already patched')
else:
    # The end of the upload loop: var_l8 is the object id, var_l9 the size, var_l7 the source address moved past
    # the data, var_p1 the descriptor.
    old = '      if (var_i1) {goto var_L4;}\n    var_B2:;\n'
    if body.count(old) != 1 or 'var_l9 = var_i1;' not in body or 'var_l7 = var_j1;' not in body:
        raise RuntimeError(f'Pinned f{function} (NullDevice::CreateBuffer) changed: upload loop end not found')
    body = body.replace(old, '      if (var_i1) {goto var_L4;}\n    pg_mesh_source(var_l8, var_l7 - (u64)var_l9, var_l9, var_p1);\n    var_B2:;\n', 1)
    s = s[:start] + body + s[end:]
    if DECLARATION not in s:
        first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
        s = s[:first.end()] + '\n' + DECLARATION + s[first.end():]
    path.write_text(s)
    print(f'mesh release: patched f{function} in {path.name}')
