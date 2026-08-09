#!/usr/bin/env bash
#
# build-apps.sh
#
# Produces SEPARATE per-architecture release builds of BeaverTail — one arm64
# (Apple Silicon) app and one x86_64 (Intel) app — rather than a single universal
# binary. Each build links the matching thin Vectorscan static library selected via
# the arch-conditional LIBRARY_SEARCH_PATHS in the Xcode project:
#   Vendor/vectorscan/lib/arm64/libhs.a
#   Vendor/vectorscan/lib/x86_64/libhs.a
#
# Output:
#   build/arm64/Build/Products/Release/BeaverTail.app   (arm64-only)
#   build/x86_64/Build/Products/Release/BeaverTail.app  (x86_64-only)
#
# Usage:
#   ./Vendor/build-apps.sh            # builds both arm64 and x86_64
#   ./Vendor/build-apps.sh arm64      # builds only the given arch(es)
#   ./Vendor/build-apps.sh x86_64
#
# Note: cross-building x86_64 on an Apple Silicon Mac is supported by the toolchain;
# the resulting Intel app should be smoke-tested on real Intel hardware before release.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PROJECT="$ROOT/BeaverTail.xcodeproj"
SCHEME="BeaverTail"
CONFIG="Release"

ARCHES=("$@")
if [ ${#ARCHES[@]} -eq 0 ]; then
  ARCHES=(arm64 x86_64)
fi

for arch in "${ARCHES[@]}"; do
  case "$arch" in
    arm64|x86_64) ;;
    *) echo "Unknown arch '$arch' (expected arm64 or x86_64)"; exit 2 ;;
  esac
  out="$ROOT/build/$arch"
  echo "==> Building $SCHEME ($CONFIG, $arch) -> $out"
  rm -rf "$out"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$out" \
    -arch "$arch" \
    ARCHS="$arch" \
    ONLY_ACTIVE_ARCH=NO \
    build
  app="$out/Build/Products/$CONFIG/$SCHEME.app/Contents/MacOS/$SCHEME"
  echo "==> $arch binary architecture:"
  lipo -info "$app"
done

echo "==> Done. Separate per-architecture apps are under $ROOT/build/<arch>/Build/Products/$CONFIG/"
