#!/bin/bash
# Compiles Strays' Metal shaders into Strays.metallib inside the app bundle.
#
# Run by Xcode as a build phase. Since Xcode 26 the Metal compiler is a
# separate download (`xcodebuild -downloadComponent MetalToolchain`). If it
# is missing this script warns and succeeds: the app then uses its
# non-shader fallback for the dissolve effect. Set REQUIRE_METAL=1 to make
# a missing compiler an error, as the release workflow does.
set -euo pipefail

source="${SRCROOT}/Strays/Shaders/Dissolve.metal"
output="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Strays.metallib"
intermediate="${DERIVED_FILE_DIR}/Dissolve.air"

if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  if [ "${REQUIRE_METAL:-0}" = "1" ]; then
    echo "error: the Metal toolchain is required for this build: xcodebuild -downloadComponent MetalToolchain"
    exit 1
  fi
  echo "warning: Metal toolchain not installed; building without the dissolve shader (xcodebuild -downloadComponent MetalToolchain)"
  rm -f "$output"
  exit 0
fi

mkdir -p "$(dirname "$output")" "$(dirname "$intermediate")"
xcrun -sdk macosx metal -c "$source" -o "$intermediate" -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET}" -Wall
xcrun -sdk macosx metallib "$intermediate" -o "$output"
