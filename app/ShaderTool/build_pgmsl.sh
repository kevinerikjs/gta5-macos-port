#!/bin/bash
# Builds the offline shader translator against the host Tint build (Build/Tint-Host).
set -euo pipefail
cd "$(dirname "$0")/.."
# TINT_BUILD: a host CMake build of Dawn/Tint (tint_cmd_tint_cmd target); OUT: the binary to write.
T="${TINT_BUILD:-Build/Tint-Host}"
OUT="${OUT:-Build/pgmsl}"
LIBS=$(tr ' ' '\n' < $T/src/tint/CMakeFiles/tint_cmd_tint_cmd.dir/link.txt | grep '\.a$' | grep -v cmd_common | sed "s|^|$T/src/tint/|")
c++ -O2 -std=c++20 -arch "${PG_HOST_ARCH:-$(uname -m)}" -mmacosx-version-min=13.0 -fno-rtti -fno-exceptions \
  -DTINT_BUILD_MSL_WRITER=1 -DTINT_BUILD_WGSL_READER=1 -DTINT_BUILD_WGSL_WRITER=1 -DTINT_BUILD_SPV_READER=0 \
  -DTINT_BUILD_SPV_WRITER=0 -DTINT_BUILD_HLSL_WRITER=0 -DTINT_BUILD_GLSL_WRITER=0 -DTINT_BUILD_GLSL_VALIDATOR=0 \
  -DTINT_BUILD_NULL_WRITER=0 -DTINT_BUILD_IR_BINARY=1 -DTINT_BUILD_IS_MAC=1 -DTINT_BUILD_IS_LINUX=0 -DTINT_BUILD_IS_WIN=0 -DNDEBUG -DDAWN_HAVE_UTILS_BUILD_CONFIG \
  -ITools/dawn -ITools/dawn/include -I$T/gen -I$T/gen/src ShaderTool/pgmsl.cc $LIBS $LIBS \
  -framework Foundation -framework Metal -framework CoreGraphics -o "$OUT"
