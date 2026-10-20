# CMake build for libsnapdarkcrypto.so — pure C, no external crypto dependency.
# SHA-256 + AES-256-GCM implemented in snapdarkcrypto.c itself, so it builds
# with a bare NDK clang and links nothing but libc (and log for debug).

cmake_minimum_required(VERSION 3.22)
project(snapdarkcrypto LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(snapdarkcrypto SHARED snapdarkcrypto.c)

# Expected signing-cert SHA-256, passed from build.gradle as a CMake variable
# (-DSNAPDARK_EXPECTED_CERT_SHA256=...). Baked in as a compile definition so the
# hash lives ONLY inside this .so — never in the DEX/BuildConfig. Empty value
# (local debug builds) leaves the signature gate off.
if(DEFINED SNAPDARK_EXPECTED_CERT_SHA256)
  target_compile_definitions(snapdarkcrypto PRIVATE
      SNAPDARK_EXPECTED_CERT_SHA256="${SNAPDARK_EXPECTED_CERT_SHA256}")
else()
  target_compile_definitions(snapdarkcrypto PRIVATE
      SNAPDARK_EXPECTED_CERT_SHA256="")
endif()

# Link liblog by name (-llog). find_library() returns the NDK sysroot STUB
# liblog.so by full path; CMake 4.x then copies that stub into the build
# output and it ends up packaged in the APK as a 4KB-aligned liblog.so.
# The compiler driver resolves -llog against the sysroot without packaging.
target_link_libraries(snapdarkcrypto log)

set_target_properties(snapdarkcrypto PROPERTIES
    C_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON)

# Release hardening: size + symbol stripping. The .so must expose nothing the
# engine does not need, and inline nothing a dump can pattern-match.
if(CMAKE_BUILD_TYPE MATCHES Release)
  target_compile_options(snapdarkcrypto PRIVATE
      -Oz -fvisibility=hidden -fno-unwind-tables -fno-asynchronous-unwind-tables)
  target_link_options(snapdarkcrypto PRIVATE
      -flto -Wl,--gc-sections -Wl,--exclude-libs,ALL -s)
  target_compile_options(snapdarkcrypto PRIVATE -flto)
endif()

# Export ONLY JNI_OnLoad — every other symbol (the registered native methods
# are opaque statics) stays out of .dynsym, so symbol-based analysis finds no
# Java_* anchors. Debug builds keep the same surface for consistency.
target_link_options(snapdarkcrypto PRIVATE
    -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/snapdark.map
    # Play 16KB page-size requirement (Nov 2025): NDK r25 links 4KB-aligned
    # by default — must opt in to 16KB ELF LOAD alignment explicitly.
    -Wl,-z,max-page-size=16384)

# Integrity mesh (SECURITY_PLAN.md Phase 5): CI bakes the SHA-256 of the Dart
# AOT blob (libapp.so) into libapp_sha256.h (committed STUB with a blank hash;
# build-apk.yml overwrites it with the per-ABI real hashes). The .c includes the
# header when this is defined; a blank/none macro leaves the gate OPEN, so local
# debug builds are unaffected even though the code is compiled in.
target_compile_definitions(snapdarkcrypto PRIVATE SNAPDARK_HAVE_LIBAPP_SHA256=1)