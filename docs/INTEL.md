# Experimental Intel Mac port

This checkout adds an experimental x86_64 Mac Catalyst build to upstream
commit `57be6eb` (public app version 1.5.2). It does not reconstruct the newer
1.6.2 native engine from the compiled app.

## Build

Requires Xcode with Mac Catalyst support, Python 3, CMake, and XcodeGen.
Use a native Intel shell/Python on an Intel Mac. WABT 1.0.42 has no Intel Mac
release binary, so preparation builds its checksum-verified source release.

The upstream shader translator is ARM64-only. For this experiment, reuse
Metal GPU shaders and reflection from the existing local Mac app. The importer
checks that every required shader ID and stage matches the game index. The
smoke test reused resources from a local v1.6.2 Mac app. This
check does not establish renderer-version or Intel GPU compatibility.

From this repository:

```sh
export PG_MAC_ARCH=x86_64
export PG_NO_STATS=1
export PG_PREBUILT_SHADER_DIR="/path/to/GTA V Port.app/Contents/Resources"
./build_mac_app.sh --mirror /path/to/game-folder
```

The game folder must contain `data/manifest.json` and
`b/8b0b5899ed/game.wasm`. Use game files you already have. Preparation verifies
the engine checksum. Build outputs are in `app/Build/Mac` and
`GTA5Port-mac.zip`. The original downloaded application is not modified.

`PG_MAC_ARCH` defaults to the build host architecture. Dependencies are cached
with their architecture in the cache key, but the current output folders hold
one architecture at a time; this is not a universal app build.

## Changes

- Select the Intel Catalyst target in the app and Opus/Blink library builds.
- Build WABT locally on Intel rather than trying to execute ARM64 host tools.
- Prepare only Catalyst resources when building the Mac app.
- Use x86 `pause` in the mesh page-state spin loop, and x86 page-fault error
  bit 1 to distinguish reads from writes in its fault handler.
- Use the actual system VM page size for heap reuse and `mincore` diagnostics.
  The old 16 KB assumption undersized the residency buffer fourfold on Intel
  (4 KB pages), corrupting the heap during periodic memory reporting.
- Use Blink's bundled `strchrnul` implementation with older Catalyst SDKs.
- Allow explicitly supplied local Metal shader resources after index checks.

The optional ARM stack-sampling profiler is disabled on Intel. Ordinary thread
CPU accounting remains available, and diagnostic symbol lookup uses `dladdr`.

## Validation

- Opus and Blink static libraries: verified x86_64 with `lipo`.
- wasm2c host executable: verified x86_64 with `file`.
- `sh app/Scripts/check_runtime.sh`: passes memory64 wait/notify, timeout,
  partial wake, shared SIMD, and trap tests on Intel.
- Mesh-release source passes the Intel Catalyst compiler syntax check.
- `Tests/mesh_faults.c`, linked with the real mesh-release implementation,
  passes protected-page read/write restoration in mode 1 and correctly
  distinguishes orphan-page reads from writes in mode 2.
- Shader importer accepts the 4,808 required shader IDs/stages and rejects
  an incompatible index. Three asset-free importer tests cover cached-index
  rebuilds, stage mismatches, and invalid library headers.

The optimized Intel Catalyst build succeeds, and the packaged app passes
`codesign --verify --strict`. LaunchServices opens the app on the Intel Mac,
and its startup log detects Intel Iris Plus Graphics. The test machine ran macOS 14.7.8 with Xcode 16.0 and 16 GB RAM.

The GTA V sandbox visibly rendered the
character, city, pedestrians and HUD on Intel Iris Plus Graphics. The first
periodic `Engine memory held` report completed, followed by continued rendering
at approximately 22 FPS in the observed short sample. Startup shader compilation
was slower. This is a short sandbox smoke test, not a Story Mode or long-term
stability test. Apple Silicon and iOS builds were not rerun for this change.

Run the runtime, importer, and mesh fault checks from the repository root:

```sh
sh app/Scripts/check_runtime.sh
python3 -m unittest discover -s app/Tests -p test_import_mac_shaders.py
mkdir -p app/Build/Probe
xcrun clang -O1 app/Tests/mesh_faults.c app/Source/NativeMeshRelease.c -o app/Build/Probe/mesh-faults
PG_MESH_RELEASE=1 app/Build/Probe/mesh-faults
PG_MESH_RELEASE=2 app/Build/Probe/mesh-faults
```

## Packaging and update limitations

The build script packages `GTA V Port.app` into `GTA5Port-mac.zip`. Keep an Intel
build separate from an existing Apple Silicon build. Upstream update prompts
currently point to Apple Silicon releases and do not provide Intel updates.
No application binaries, game files, generated engine C, shader libraries,
reflection data, or local logs are included in the source change.
