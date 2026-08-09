# Vendored Vectorscan

BeaverTail accelerates regex filtering and highlight matching with
[Vectorscan](https://github.com/VectorCamp/vectorscan) — the portable fork of
Intel Hyperscan that supports both Apple Silicon (arm64 / NEON) and Intel
(x86_64 / SSE4.2).

## Layout

```
Vendor/
  build-vectorscan.sh          # reproducible library build script
  build-apps.sh                # produces separate per-arch app builds
  vectorscan/
    lib/arm64/libhs.a          # static library linked into the arm64 app
    lib/x86_64/libhs.a         # static library linked into the x86_64 app
    include/hs/*.h             # public C headers (hs.h and friends)
```

## Why static?

The library is linked as a **static archive** (`libhs.a`) via the app target's
`OTHER_LDFLAGS` (`-lhs -lc++`), with `HEADER_SEARCH_PATHS` pointing here and the C
API exposed to Swift through `BeaverTail/BeaverTail-Bridging-Header.h`
(`#import <hs/hs.h>`). This keeps each shipped, notarizable app self-contained —
there is **no runtime dependency** on a Homebrew dylib.

## Separate per-architecture builds

BeaverTail is built as **separate single-architecture apps** — one arm64 (Apple
Silicon) and one x86_64 (Intel) — rather than a single universal binary. The Xcode
project selects the matching static library per architecture via arch-conditional
build settings on the app target:

```
LIBRARY_SEARCH_PATHS[arch=arm64]  = $(SRCROOT)/Vendor/vectorscan/lib/arm64
LIBRARY_SEARCH_PATHS[arch=x86_64] = $(SRCROOT)/Vendor/vectorscan/lib/x86_64
```

The project also pins `ARCHS = arm64` in every build configuration, so it **never**
produces a universal binary by accident — a plain build or Xcode Archive is arm64-only.
The Intel app is produced by overriding the architecture on the command line
(`ARCHS=x86_64`), which `build-apps.sh` does for you.

Build both apps with:

```sh
./Vendor/build-apps.sh            # both arm64 and x86_64
./Vendor/build-apps.sh arm64      # a single arch
```

Output lands in `build/<arch>/Build/Products/Release/BeaverTail.app`. Each binary is
single-architecture (verify with `lipo -info <app>/Contents/MacOS/BeaverTail`).

> Cross-building the x86_64 app on an Apple Silicon Mac is supported by the toolchain,
> but smoke-test the Intel app on real Intel hardware before release.

## Version

Pinned to `vectorscan/5.4.12`.

## Rebuilding / updating the library

Install the build-time tools and run the script:

```sh
brew install cmake ragel boost pkg-config ninja
./Vendor/build-vectorscan.sh
```

This regenerates `vectorscan/lib/arm64/libhs.a`, `vectorscan/lib/x86_64/libhs.a`, and
`vectorscan/include/hs/*.h`. Those artifacts are committed, so a normal checkout builds
without running the script.

## Architectures

The committed libraries are **separate thin static archives** per architecture —
`arm64` (Apple Silicon / NEON) and `x86_64` (Intel / SSE4.2, `-march=x86-64-v2`).

Verify with:

```sh
lipo -info Vendor/vectorscan/lib/arm64/libhs.a   # …is architecture: arm64
lipo -info Vendor/vectorscan/lib/x86_64/libhs.a  # …is architecture: x86_64
```
