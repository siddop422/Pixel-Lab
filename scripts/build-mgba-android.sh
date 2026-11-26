#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MGBA_SOURCE="$ROOT/third_party/mgba"
NATIVE_SOURCE="$ROOT/native/mgba"
BUILD_DIR="$ROOT/build/mgba-android-arm64"
OUTPUT_DIR="$ROOT/artifacts/native/android-arm64"

if [[ ! -f "$MGBA_SOURCE/CMakeLists.txt" ]]; then
  echo "Pinned mGBA checkout missing: $MGBA_SOURCE" >&2
  exit 1
fi

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$NDK" && -n "${ANDROID_HOME:-}" ]]; then
  NDK="$(find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n 1)"
fi
if [[ -z "$NDK" || ! -f "$NDK/build/cmake/android.toolchain.cmake" ]]; then
  echo "Android NDK not found. Set ANDROID_NDK_HOME or install an NDK under ANDROID_HOME." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
cmake -S "$NATIVE_SOURCE" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_NDK="$NDK" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-23 \
  -DANDROID_STL=c++_static \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DPGB_NATIVE_OUTPUT_DIR="$OUTPUT_DIR" \
  -DLIBMGBA_ONLY=ON \
  -DUSE_LZMA=ON \
  -DM_CORE_GBA=ON \
  -DM_CORE_GB=ON \
  -DBUILD_TEST=OFF \
  -DBUILD_SUITE=OFF \
  -DBUILD_CINEMA=OFF \
  -DENABLE_DEBUGGERS=OFF \
  -DENABLE_SCRIPTING=OFF \
  -DUSE_PTHREADS=ON \
  -DUSE_PNG=OFF \
  -DUSE_ZLIB=OFF \
  -DUSE_LIBZIP=OFF \
  -DUSE_MINIZIP=OFF \
  -DUSE_SQLITE3=OFF \
  -DUSE_FFMPEG=OFF \
  -DUSE_LUA=OFF \
  -DUSE_JSON_C=OFF \
  -DUSE_EDITLINE=OFF \
  -DBUILD_GL=OFF \
  -DBUILD_GLES2=OFF \
  -DBUILD_GLES3=OFF

cmake --build "$BUILD_DIR" --target pocketgb_mgba --parallel "${ANDROID_BUILD_JOBS:-2}"

LIBRARY="$OUTPUT_DIR/libpocketgb-mgba.so"
if [[ ! -f "$LIBRARY" ]]; then
  echo "Native Android mGBA library missing: $LIBRARY" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR/licenses"
cp "$MGBA_SOURCE/LICENSE" "$OUTPUT_DIR/licenses/mGBA-MPL-2.0.txt"
cat > "$OUTPUT_DIR/mGBA-BUILD.txt" <<'EOF'
mGBA upstream revision: 431935616c0e216d650b25b2ea0c0acccd359038
Target: Android arm64-v8a (Android 6.0 / API 23+)
Build mode: core-only (GBA + GB), no desktop frontend
License: Mozilla Public License 2.0
EOF

echo "Built Android native mGBA library: $LIBRARY ($(du -h "$LIBRARY" | cut -f1))"
