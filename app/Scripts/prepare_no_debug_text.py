"""The B key no longer turns on the game's debug text.

CApp::UpdateState flips rage::grcDebugDraw's "display debug text" flag whenever the keyboard's B (Windows key 0x42)
is newly pressed, a developer shortcut this build kept. With the flag on, scripts draw their debug labels in small
blue text (the vending machine's "runVendingMachine", "playerOutOfRange"; log qywfxc). Players turn it on without
knowing: B on a Mac or Bluetooth keyboard, or a word with a b typed through the Mods keyboard's Type (a trainer's
vehicle search: "bati", "banshee"). The toggle now always writes off, so B does nothing here and a press turns the
text off again. CDebug::Init still clears the flag at start, and the engine's own short forced uses (save, force on,
restore) are unchanged.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
function = fn('CApp::UpdateState(int, int, rage::fwFsm::Event)')
setter = fn('rage::grcDebugDraw::SetDisplayDebugText(bool)')
MARK = '/* pg: B no longer turns on debug text */'
files = sorted((root / 'Generated').glob('game_*.c'))
# The flag's address, from SetDisplayDebugText (its only store).
setter_file = next(p for p in files if re.search(rf'^void w2c_game_f{setter}\(w2c_game\* instance', p.read_text(), re.M))
setter_body = setter_file.read_text()
setter_start = re.search(rf'^void w2c_game_f{setter}\(w2c_game\* instance[^\n]*\{{$', setter_body, re.M).start()
flag = re.findall(r'var_j0 = (\d+)ull;', setter_body[setter_start:setter_body.index('\n}\n', setter_start)])
if len(flag) != 1:
    raise RuntimeError(f'Pinned f{setter} (SetDisplayDebugText) changed: flag address not found')
flag = flag[0]
path = next(p for p in files if re.search(rf'^\w+ w2c_game_f{function}\(w2c_game\* instance', p.read_text(), re.M))
s = path.read_text()
head = re.search(rf'^\w+ w2c_game_f{function}\(w2c_game\* instance[^\n]*\{{$', s, re.M)
start = head.start(); end = s.index('\n}\n', start) + 3
body = s[start:end]
if MARK in body:
    print(f'debug text key: f{function} already patched')
else:
    old = (f'  var_j0 = {flag}ull;\n  var_j1 = {flag}ull;\n'
           '  var_i1 = i32_load8_u_shared(wasm_rt_local_memory_base, wasm_rt_local_memory_size, instance->w2c_env_memory, (u64)(var_j1));\n'
           '  var_i2 = 1u;\n  var_i1 ^= var_i2;\n')
    if body.count(old) != 1:
        raise RuntimeError(f'Pinned f{function} (CApp::UpdateState) changed: debug text toggle not found')
    body = body.replace(old, old.replace('  var_i1 ^= var_i2;\n', f'  var_i1 = 0u; {MARK}\n'), 1)
    path.write_text(s[:start] + body + s[end:])
    print(f'debug text key: patched f{function} in {path.name}')
