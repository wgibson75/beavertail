#!/usr/bin/env bash
#
# build-vectorscan.sh
#
# Reproducibly builds the vendored Vectorscan static libraries that BeaverTail links
# against, as SEPARATE per-architecture thin archives (not a universal binary):
#   Vendor/vectorscan/lib/arm64/libhs.a    (Apple Silicon / NEON)
#   Vendor/vectorscan/lib/x86_64/libhs.a   (Intel / SSE4.2)
# plus its public headers (Vendor/vectorscan/include/hs/*.h).
#
# The app builds one architecture at a time (see Vendor/build-apps.sh); the Xcode
# project selects the matching library via arch-conditional LIBRARY_SEARCH_PATHS. We
# link Vectorscan as a *static* archive so each shipped, notarizable app stays
# self-contained with no runtime dependency on a Homebrew dylib.
#
# Vectorscan is the portable fork of Intel Hyperscan; it supports both Apple Silicon
# (arm64 / NEON) and Intel (x86_64 / SSE4.2).
#
# Build-time tools required (Homebrew): cmake, ragel, boost, pkg-config, ninja.
#   brew install cmake ragel boost pkg-config ninja
# Cross-building the x86_64 slice on Apple Silicon also needs Rosetta.
#
# Usage:
#   ./Vendor/build-vectorscan.sh
#
# The produced per-arch libhs.a / headers are committed under Vendor/vectorscan so a
# normal checkout builds without needing this script; re-run it only to update
# Vectorscan.


set -euo pipefail

VERSION="vectorscan/5.4.12"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/vectorscan-src"
DST="$HERE/vectorscan"
BOOST_ROOT="${BOOST_ROOT:-/opt/homebrew}"

echo "==> Cloning Vectorscan $VERSION"
rm -rf "$SRC"
git clone --depth 1 --branch "$VERSION" https://github.com/VectorCamp/vectorscan.git "$SRC"

# Builds the static libhs.a for one architecture into build-<arch>/lib/libhs.a.
build_arch() {
  local arch="$1"
  echo "==> Configuring ($arch, static, Release)"
  cmake -S "$SRC" -B "$SRC/build-$arch" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DFAT_RUNTIME=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_UNIT=OFF \
    -DBUILD_DOC=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DBOOST_ROOT="$BOOST_ROOT"
  echo "==> Building libhs.a ($arch)"
  ninja -C "$SRC/build-$arch" hs
}

build_arch arm64
build_arch x86_64   # portable baseline: -march=x86-64-v2 -msse4.2 (auto-selected)

echo "==> Staging per-architecture static libraries"
rm -rf "$DST"
mkdir -p "$DST/lib/arm64" "$DST/lib/x86_64" "$DST/include/hs"
cp "$SRC/build-arm64/lib/libhs.a"  "$DST/lib/arm64/libhs.a"
cp "$SRC/build-x86_64/lib/libhs.a" "$DST/lib/x86_64/libhs.a"

echo "==> Staging public headers"
cp "$SRC/src/hs.h" "$SRC/src/hs_common.h" "$SRC/src/hs_compile.h" \
   "$SRC/src/hs_runtime.h" "$SRC/build-arm64/hs_version.h" "$DST/include/hs/"

echo "==> Cleaning up build tree"
rm -rf "$SRC"

echo "==> Done:"
lipo -info "$DST/lib/arm64/libhs.a"
lipo -info "$DST/lib/x86_64/libhs.a"
ls "$DST/include/hs"
