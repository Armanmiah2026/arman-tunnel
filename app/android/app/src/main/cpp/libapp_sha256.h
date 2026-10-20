// STUB for local builds — the REAL per-ABI hashes are baked by CI.
//
// build-apk.yml overwrites this file with the SHA-256 of each ABI's libapp.so,
// then rebuilds; this committed version keeps local debug builds compiling and
// leaves the mesh gate OPEN (blank hash = gate off). It must NOT be edited by
// hand — the workflow regenerates it from the just-built APKs.
#ifndef LIBAPP_SHA256_H
#define LIBAPP_SHA256_H
#if defined(__aarch64__)
#define SNAPDARK_EXPECTED_LIBAPP_SHA256 ""
#else
#define SNAPDARK_EXPECTED_LIBAPP_SHA256 ""
#endif
#endif