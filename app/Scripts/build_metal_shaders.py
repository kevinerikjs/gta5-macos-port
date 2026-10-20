#!/usr/bin/env python3
"""Precompiles the game's translated shaders for the native Metal renderer.

The game ships its shaders as WGSL (b/<build>/shaders: index.json, <hash>.wgsl, <hash>.consts.json). This script
translates every vertex, pixel and compute shader to Metal Shading Language with ShaderTool/pgmsl (Tint, with the
D3D11 register slots mapped straight onto Metal argument indices), compiles them to AIR in parallel and links one
metallib per SDK. It also writes the reflection table the renderer loads at startup (one JSON object per line).

Outputs (GeneratedResources/, bundled by project.yml):
  shaders-<sdk>.metallib   every shader, entry point s_<hash>
  shader-reflection.jsonl  bindings, stage inputs/outputs, workgroup sizes, constant tables

Usage: build_metal_shaders.py <shader dir> [--sdk iphoneos|iphonesimulator ...]
"""
import argparse, concurrent.futures, json, os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, 'Build', 'MetalShaders')
OUT = os.path.join(ROOT, 'GeneratedResources')
# The oldest iOS the app runs on (project.yml deploymentTarget); a metallib built for a newer one won't load.
TARGETS = {'iphoneos': 'air64-apple-ios16.0', 'iphonesimulator': 'air64-apple-ios16.0-simulator',
           'maccatalyst': 'air64-apple-ios16.0-macabi'}
TOOL_SDK = {'maccatalyst': 'macosx'}  # Mac Catalyst uses the macOS Metal toolchain


def run(cmd, cwd=None):
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if r.returncode:
        raise RuntimeError(' '.join(cmd) + '\n' + r.stderr[-2000:])


def compile_batch(sdk, compiler, sources, air):
    """Compiles a batch of .metal files in one compiler process (process start-up dominates single-file compiles)."""
    tmp = tempfile.mkdtemp(dir=air)
    try:
        run([compiler, '-c', '-std=metal3.0', '-target', TARGETS[sdk], '-ffast-math', '-Wno-unused-variable'] + sources, cwd=tmp)
        for src in sources:
            name = os.path.splitext(os.path.basename(src))[0] + '.air'
            os.replace(os.path.join(tmp, name), os.path.join(air, name))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('shaders')
    ap.add_argument('--sdk', action='append', choices=sorted(TARGETS))
    args = ap.parse_args()
    sdks = args.sdk or ['iphoneos', 'iphonesimulator']
    tool = os.environ.get('PGMSL') or os.path.join(ROOT, 'Tools', 'pgmsl', 'pgmsl')
    if not os.path.exists(tool):
        sys.exit('The shader translator is missing: run Scripts/fetch_shader_tool.py (or build it with ShaderTool/build_pgmsl.sh).')
    index = json.load(open(os.path.join(args.shaders, 'index.json')))
    msl = os.path.join(WORK, 'msl')
    os.makedirs(msl, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    entries = [(h, r) for h, r in index.items() if not h.startswith('_') and r.get('ok') and r['stage'] in ('vs', 'ps', 'cs')]
    listing = os.path.join(WORK, 'list.txt')
    with open(listing, 'w') as f:
        for h, r in entries:
            f.write('%s %s %s\n' % (h, r['stage'], os.path.join(args.shaders, h + '.wgsl')))
    reflection = os.path.join(WORK, 'reflection.jsonl')
    r = subprocess.run([tool, listing, msl, reflection], capture_output=True, text=True)
    print(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'pgmsl: no output')
    if r.returncode:
        sys.exit(r.stderr)

    # reflection + labels + constant tables (binding 15: one u32 per 16-byte row)
    with open(os.path.join(OUT, 'shader-reflection.jsonl'), 'w') as out:
        for line in open(reflection):
            o = json.loads(line)
            rec = index[o['h']]
            o['label'] = rec.get('effect', '?') + '::' + rec.get('program', '?')
            if rec.get('consts'):
                o['k'] = json.load(open(os.path.join(args.shaders, o['h'] + '.consts.json')))
            out.write(json.dumps(o, separators=(',', ':')) + '\n')

    hashes = [json.loads(l)['h'] for l in open(reflection)]
    for sdk in sdks:
        air = os.path.join(WORK, 'air-' + sdk + '-' + TARGETS[sdk].split('-')[2])  # a new target compiles afresh
        os.makedirs(air, exist_ok=True)
        compiler = subprocess.run(['xcrun', '-sdk', TOOL_SDK.get(sdk, sdk), '-f', 'metal'], capture_output=True, text=True).stdout.strip()
        stale = []
        for h in hashes:
            src, dst = os.path.join(msl, h + '.metal'), os.path.join(air, h + '.air')
            if not (os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src)):
                stale.append(src)
        batches = [stale[i:i + 48] for i in range(0, len(stale), 48)]
        failed = 0
        with concurrent.futures.ThreadPoolExecutor(os.cpu_count() or 8) as pool:
            for fut in concurrent.futures.as_completed([pool.submit(compile_batch, sdk, compiler, b, air) for b in batches]):
                try:
                    fut.result()
                except Exception as e:
                    failed += 1
                    if failed <= 3:
                        print(str(e)[-3000:])
        print('%s: compiled %d shaders in %d batches' % (sdk, len(stale), len(batches)))
        files = os.path.join(WORK, 'air-' + sdk + '.txt')
        with open(files, 'w') as f:
            for h in hashes:
                f.write(os.path.join(air, h + '.air') + '\n')
        lib = os.path.join(OUT, 'shaders-%s.metallib' % sdk)
        run(['xcrun', '-sdk', TOOL_SDK.get(sdk, sdk), 'metallib', '@' + files, '-o', lib])
        print('%s: %d shaders, %.1f MB' % (sdk, len(hashes), os.path.getsize(lib) / 1048576))


if __name__ == '__main__':
    main()
