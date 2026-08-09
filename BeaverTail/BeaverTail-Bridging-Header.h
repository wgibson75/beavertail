//
//  BeaverTail-Bridging-Header.h
//  BeaverTail
//
//  Objective-C / C bridging header for the app target. Exposes the Vectorscan
//  (Hyperscan-compatible) C API to Swift so `VectorscanEngine.swift` can compile
//  and run block-mode regex databases. The library is vendored as per-architecture
//  static archives (Vendor/vectorscan/lib/{arm64,x86_64}/libhs.a), selected via the
//  app target's arch-conditional LIBRARY_SEARCH_PATHS and linked via OTHER_LDFLAGS,
//  so each shipped single-architecture app stays self-contained and notarizable —
//  no runtime dependency on a Homebrew dylib.
//

#ifndef BeaverTail_Bridging_Header_h
#define BeaverTail_Bridging_Header_h

#import <hs/hs.h>

#endif /* BeaverTail_Bridging_Header_h */
