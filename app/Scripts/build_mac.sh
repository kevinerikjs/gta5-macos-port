#!/bin/sh
# The Mac Catalyst app. Defaults to the host CPU; PG_MAC_ARCH selects arm64 or x86_64.
# Writes Build/Mac/Build/Products/Release-maccatalyst/PlayGTA5Native.app (signed to run on this Mac).
set -eu
MAC_ARCH="${PG_MAC_ARCH:-$(uname -m)}"
case "$MAC_ARCH" in arm64|x86_64) ;; *) echo "Unsupported Mac architecture: $MAC_ARCH" >&2; exit 1 ;; esac
export PG_MAC_ARCH="$MAC_ARCH"
cd "$(dirname "$0")/.."
# The same engine patches as the iPhone build, read from build_native.sh so the two lists can't drift.
grep -E '^python3 Scripts/(generate_imports|prepare_)' Scripts/build_native.sh | sh -e
python3 Scripts/build_opus.py --sdk maccatalyst
python3 Scripts/build_blink.py --sdk maccatalyst
if [ -n "${PG_PREBUILT_SHADER_DIR:-}" ]; then
  python3 Scripts/import_mac_shaders.py --source "$PG_PREBUILT_SHADER_DIR" --index Resources/shader-index.json
else
  python3 Scripts/build_metal_shaders.py "${PG_SHADER_DIR:-Build/Inputs/shaders}" --sdk maccatalyst
fi
xcodegen generate --spec project.yml
# The bundled libarchive is iPhone-only; the Mac links macOS's own (project.yml, -larchive).
sed -i '' 's|\(/\* libarchive.xcframework in Frameworks \*/ = {isa = PBXBuildFile; \)|\1platformFilter = ios; |' PlayGTA5Native.xcodeproj/project.pbxproj
# PG_NO_STATS=1: the developer's own test builds send no play stats (App/Analytics.swift).
set --
if [ -n "${PG_NO_STATS:-}" ]; then set -- "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) PG_NO_STATS"; fi
# Profile-guided optimization (GTA-172/216), as build_ipa.sh: PG_PGO_PROFILE (.profdata) and PG_ORDER_FILE (hot functions).
if [ -n "${PG_PGO_PROFILE:-}" ]; then set -- "$@" "OTHER_CFLAGS=\$(inherited) -fprofile-instr-use=$PG_PGO_PROFILE -Wno-profile-instr-unprofiled"; fi
if [ -n "${PG_ORDER_FILE:-}" ]; then set -- "$@" "OTHER_LDFLAGS=\$(inherited) -Wl,-order_file,$PG_ORDER_FILE"; fi
xcodebuild -project PlayGTA5Native.xcodeproj -scheme PlayGTA5Native \
  -configuration Release -destination "platform=macOS,variant=Mac Catalyst,arch=$MAC_ARCH" \
  -derivedDataPath Build/Mac -jobs "${MAC_JOBS:-3}" ARCHS="$MAC_ARCH" ONLY_ACTIVE_ARCH=YES \
  GCC_OPTIMIZATION_LEVEL=2 SWIFT_OPTIMIZATION_LEVEL=-O DEBUG_INFORMATION_FORMAT=dwarf \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=App/Mac.entitlements \
  "$@" build
