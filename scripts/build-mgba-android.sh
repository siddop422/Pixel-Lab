#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MGBA_SOURCE="$ROOT/third_party/mgba"
NATIVE_SOURCE="$ROOT/native/mgba"

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

# .NET 10 Android runtime identifiers mapped to Android NDK ABI names.
declare -a ABI_PAIRS=(
  "android-arm64:arm64-v8a"
  "android-arm:armeabi-v7a"
  "android-x64:x86_64"
  "android-x86:x86"
)

for pair in "${ABI_PAIRS[@]}"; do
  RID="${pair%%:*}"
  ABI="${pair#*:}"
  BUILD_DIR="$ROOT/build/mgba-$RID"
  OUTPUT_DIR="$ROOT/artifacts/native/$RID"

  echo "==> Building pinned mGBA core for $ABI ($RID)"
  mkdir -p "$OUTPUT_DIR"

  cmake -S "$NATIVE_SOURCE" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_NDK="$NDK" \
    -DANDROID_ABI="$ABI" \
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
    echo "Native Android mGBA library missing for $ABI: $LIBRARY" >&2
    exit 1
  fi

  mkdir -p "$OUTPUT_DIR/licenses"
  cp "$MGBA_SOURCE/LICENSE" "$OUTPUT_DIR/licenses/mGBA-MPL-2.0.txt"
  cat > "$OUTPUT_DIR/mGBA-BUILD.txt" <<EOF
mGBA upstream revision: 431935616c0e216d650b25b2ea0c0acccd359038
Target: Android $ABI (Android 6.0 / API 23+)
Runtime identifier: $RID
Build mode: core-only (GBA + GB), no desktop frontend
License: Mozilla Public License 2.0
EOF

  echo "Built $ABI native library: $LIBRARY ($(du -h "$LIBRARY" | cut -f1))"
done

echo "All four Android native backends built successfully."
