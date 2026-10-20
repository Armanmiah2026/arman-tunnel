/*
 * libsnapdarkcrypto.so — ALL config crypto lives here, NOT in the DEX.
 *
 * Pure C with NO external crypto library: SHA-256 and AES-256-GCM are
 * implemented in this file (Brad Conte-style, public domain), so it builds
 * with a bare NDK clang and needs nothing from the platform.
 *
 * The DEX (AppSecurity.kt) only declares JNI externals — zero secrets, zero
 * crypto logic. pepper/seeds are built from fragments at runtime.
 *
 * JNI surface (class com.snapdark.tunnel.AppSecurity):
 *   nativeCertSha256([B)Ljava/lang/String;
 *   nativeIntegrityOk([B)Z
 *   nativeDecrypt(Ljava/lang/String;[BLjava/lang/String;)Ljava/lang/String;
 *   nativeVipIssue([BLjava/lang/String;J)Ljava/lang/String;
 *   nativeVipVerify([BLjava/lang/String;Ljava/lang/String;)J
 */

#include <jni.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

/*
 * Expected signing-cert SHA-256, baked at compile time (build.gradle passes
 * -DSNAPDARK_EXPECTED_CERT_SHA256=... -> target_compile_definitions). Empty
 * means the signature gate is off (local debug builds). The value NEVER
 * crosses JNI — it exists only inside this .so, so the DEX has no copy.
 */
#ifndef SNAPDARK_EXPECTED_CERT_SHA256
#define SNAPDARK_EXPECTED_CERT_SHA256 ""
#endif

/* Integrity mesh (SECURITY_PLAN.md Phase 5): CI bakes the SHA-256 of the Dart
 * AOT blob (libapp.so) into libapp_sha256.h and defines SNAPDARK_HAVE_LIBAPP_SHA256.
 * The gate below hashes libapp.so RESIDENT ON DISK next to this library and
 * compares it to the baked per-ABI macro (±__aarch64__). No header on local
 * builds => macro absent => gate off. "none" (workflow wrote an empty value)
 * also means off.
 */
#ifdef SNAPDARK_HAVE_LIBAPP_SHA256
#include "libapp_sha256.h"
#ifndef SNAPDARK_EXPECTED_LIBAPP_SHA256
#define SNAPDARK_EXPECTED_LIBAPP_SHA256 ""
#endif
#endif

/* ================================================================== strings
 *
 * Every constant a reverse engineer could eat with `strings` — key-derivation
 * peppers, envelope prefixes, watchdog needles — is stored XOR-scrambled and
 * decoded into a stack buffer only for the moment it is used, then zeroed.
 * .rodata shows nothing but noise.
 */

static void secure_zero(void *p, size_t n) {
    volatile unsigned char *v = (unsigned char *)p;
    while (n--) *v++ = 0;
}

/* Decode an XOR-scrambled constant into a caller-provided stack buffer. */
static void ob_decode(const unsigned char *ob, size_t n, unsigned char k,
                      char *out, size_t cap) {
    if (cap == 0) return;
    size_t i = 0;
    for (; i < n && i < cap - 1; i++) out[i] = (char)(ob[i] ^ k);
    out[i] = 0;
}

static const unsigned char OB_V3_PEPPER[] = {0x3b, 0x28, 0x37, 0x3b, 0x34, 0x60, 0x60, 0x39, 0x3c, 0x3d, 0x60, 0x60, 0x2c, 0x69, 0x60, 0x60, 0x68, 0x6a, 0x68, 0x6c};
#define OB_V3_PEPPER_LEN 20
#define OB_V3_PEPPER_KEY 0x5A

static const unsigned char OB_V2_SEED[] = {0x76, 0x45, 0x5a, 0x56, 0x59, 0x63, 0x42, 0x59, 0x59, 0x52, 0x5b, 0x0d, 0x76, 0x45, 0x5a, 0x56, 0x59, 0x5a, 0x5e, 0x56, 0x5f, 0x05, 0x07, 0x05, 0x01, 0x0d, 0x41, 0x05};
#define OB_V2_SEED_LEN 28
#define OB_V2_SEED_KEY 0x37

static const unsigned char OB_V1_KEY[] = {0x2f, 0x1c, 0x03, 0x0f, 0x00, 0x3a, 0x1b, 0x00, 0x00, 0x0b, 0x02, 0x54, 0x2f, 0x1c, 0x03, 0x0f, 0x00, 0x03, 0x07, 0x0f, 0x06, 0x5c, 0x5e, 0x5c, 0x58};
#define OB_V1_KEY_LEN 25
#define OB_V1_KEY_KEY 0x6E

static const unsigned char OB_V3_PREFIX[] = {0x52, 0x44, 0x4F, 0x52, 0x44, 0x48, 0x1B, 0x57, 0x12, 0x1B};
#define OB_V3_PREFIX_LEN 10
#define OB_V3_PREFIX_KEY 0x21

static const unsigned char OB_V2_PREFIX[] = {0x31, 0x27, 0x2C, 0x31, 0x27, 0x2B, 0x78, 0x34, 0x70, 0x78};
#define OB_V2_PREFIX_LEN 10
#define OB_V2_PREFIX_KEY 0x42

static const unsigned char OB_V1_PREFIX[] = {0x00, 0x16, 0x1D, 0x00, 0x16, 0x1A, 0x49, 0x05, 0x42, 0x49};
#define OB_V1_PREFIX_LEN 10
#define OB_V1_PREFIX_KEY 0x73

static const unsigned char OB_TRACER[] = {0x5B, 0x7D, 0x6E, 0x6C, 0x6A, 0x7D, 0x5F, 0x66, 0x6B, 0x35};
#define OB_TRACER_LEN 10
#define OB_TRACER_KEY 0x0F

static const unsigned char OB_N_FRIDA[] = {0x4B, 0x5F, 0x44, 0x49, 0x4C, 0x00};
#define OB_N_FRIDA_LEN 6
#define OB_N_FRIDA_KEY 0x2D

static const unsigned char OB_N_GADGET[] = {0x36, 0x30, 0x35, 0x36, 0x34, 0x25};
#define OB_N_GADGET_LEN 6
#define OB_N_GADGET_KEY 0x51

static const unsigned char OB_N_GUMJS[] = {0x5E, 0x4C, 0x54, 0x14, 0x53, 0x4A, 0x14, 0x55, 0x56, 0x56, 0x49};
#define OB_N_GUMJS_LEN 11
#define OB_N_GUMJS_KEY 0x39

static const unsigned char OB_N_LINJECT[] = {0x2B, 0x2E, 0x29, 0x2D, 0x22, 0x24, 0x33, 0x28, 0x35};
#define OB_N_LINJECT_LEN 9
#define OB_N_LINJECT_KEY 0x47

static const unsigned char OB_N_PFRIDA[] = {0x1B, 0x04, 0x04, 0x07, 0x46, 0x0D, 0x19, 0x02, 0x0F, 0x0A};
#define OB_N_PFRIDA_LEN 10
#define OB_N_PFRIDA_KEY 0x6B

/* VIP unlock tickets (2026-10): cert-bound AES-256-GCM envelope issued by
 * native so a root-edited SharedPreferences line cannot mint VIP access.
 * Key = SHA-256(certHex + ":" + VIP_SEED). This seed NEVER ships outside
 * libsnapdarkcrypto.so; admin-panel/src/crypto.js mirrors the plaintext so the
 * Worker can server-verify tickets on /api/vip/resolve (first-party secret,
 * same exposure level as V2_SEED — never inside the app DEX). */
static const unsigned char OB_VIP_SEED[] = {0x1f, 0x2c, 0x33, 0x3f, 0x30, 0x0a, 0x2b, 0x30, 0x30, 0x3b, 0x32, 0x64, 0x1f, 0x2c, 0x33, 0x3f, 0x30, 0x33, 0x37, 0x3f, 0x36, 0x6c, 0x6e, 0x6c, 0x68, 0x64, 0x28, 0x37, 0x2e};
#define OB_VIP_SEED_LEN 29
#define OB_VIP_SEED_KEY 0x5E

static const unsigned char OB_VIP_PREFIX[] = {0x62, 0x74, 0x7F, 0x62, 0x74, 0x78, 0x2B, 0x67, 0x78, 0x61, 0x2B};
#define OB_VIP_PREFIX_LEN 11
#define OB_VIP_PREFIX_KEY 0x11

/* ==================================================================== SHA-256 */

typedef struct {
    uint32_t h[8];
    uint64_t len;
    unsigned char buf[64];
    size_t buflen;
} sha256_ctx;

static const uint32_t SHA_K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

static uint32_t rotr32(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static void sha256_transform(sha256_ctx *c, const unsigned char *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[i*4] << 24) | ((uint32_t)p[i*4+1] << 16) |
               ((uint32_t)p[i*4+2] << 8) | p[i*4+3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr32(w[i-15],7) ^ rotr32(w[i-15],18) ^ (w[i-15] >> 3);
        uint32_t s1 = rotr32(w[i-2],17) ^ rotr32(w[i-2],19) ^ (w[i-2] >> 10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    uint32_t a=c->h[0], b=c->h[1], cc=c->h[2], d=c->h[3],
             e=c->h[4], f=c->h[5], g=c->h[6], h=c->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = rotr32(e,6) ^ rotr32(e,11) ^ rotr32(e,25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + S1 + ch + SHA_K[i] + w[i];
        uint32_t S0 = rotr32(a,2) ^ rotr32(a,13) ^ rotr32(a,22);
        uint32_t maj = (a & b) ^ (a & cc) ^ (b & cc);
        uint32_t t2 = S0 + maj;
        h=g; g=f; f=e; e=d+t1; d=cc; cc=b; b=a; a=t1+t2;
    }
    c->h[0]+=a; c->h[1]+=b; c->h[2]+=cc; c->h[3]+=d;
    c->h[4]+=e; c->h[5]+=f; c->h[6]+=g; c->h[7]+=h;
}

static void sha256_init(sha256_ctx *c) {
    c->h[0]=0x6a09e667; c->h[1]=0xbb67ae85; c->h[2]=0x3c6ef372; c->h[3]=0xa54ff53a;
    c->h[4]=0x510e527f; c->h[5]=0x9b05688c; c->h[6]=0x1f83d9ab; c->h[7]=0x5be0cd19;
    c->len=0; c->buflen=0;
}

static void sha256_update(sha256_ctx *c, const unsigned char *data, size_t n) {
    c->len += n;
    while (n > 0) {
        size_t take = 64 - c->buflen;
        if (take > n) take = n;
        memcpy(c->buf + c->buflen, data, take);
        c->buflen += take; data += take; n -= take;
        if (c->buflen == 64) { sha256_transform(c, c->buf); c->buflen = 0; }
    }
}

static void sha256_final(sha256_ctx *c, unsigned char out[32]) {
    uint64_t bitlen = c->len * 8;
    unsigned char pad = 0x80;
    sha256_update(c, &pad, 1);
    unsigned char zero = 0;
    while (c->buflen != 56) sha256_update(c, &zero, 1);
    unsigned char lenb[8];
    for (int i = 0; i < 8; i++) lenb[i] = (unsigned char)(bitlen >> (56 - i*8));
    sha256_update(c, lenb, 8);
    for (int i = 0; i < 8; i++) {
        out[i*4]   = (unsigned char)(c->h[i] >> 24);
        out[i*4+1] = (unsigned char)(c->h[i] >> 16);
        out[i*4+2] = (unsigned char)(c->h[i] >> 8);
        out[i*4+3] = (unsigned char)c->h[i];
    }
}

static void sha256(const unsigned char *data, size_t n, unsigned char out[32]) {
    sha256_ctx c; sha256_init(&c); sha256_update(&c, data, n); sha256_final(&c, out);
}

static void sha256_hex(const unsigned char *data, size_t n, char out[65]) {
    unsigned char d[32]; sha256(data, n, d);
    static const char H[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) { out[i*2]=H[d[i]>>4]; out[i*2+1]=H[d[i]&15]; }
    out[64]=0;
}

/* ==================================================================== AES-256 */

#define AES_NR 14
#define AES_NK 8

static const unsigned char AES_S[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};

static unsigned char gf_mul(unsigned char a, unsigned char b) {
    unsigned char p = 0;
    for (int i = 0; i < 8; i++) {
        if (b & 1) p ^= a;
        unsigned char hi = a & 0x80;
        a <<= 1;
        if (hi) a ^= 0x1b;
        b >>= 1;
    }
    return p;
}

static void aes_expand_key(const unsigned char key[32], uint32_t rk[4*(AES_NR+1)]) {
    for (int i = 0; i < AES_NK; i++)
        rk[i] = ((uint32_t)key[i*4]<<24)|((uint32_t)key[i*4+1]<<16)|((uint32_t)key[i*4+2]<<8)|key[i*4+3];
    static const uint32_t RCON[15] = {0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36,0x6c,0xd8,0xab,0x4d};
    uint32_t temp;
    for (int i = AES_NK; i < 4*(AES_NR+1); i++) {
        temp = rk[i-1];
        if (i % AES_NK == 0) {
            temp = (temp << 8) | (temp >> 24); /* RotWord */
            unsigned char b0=AES_S[temp>>24], b1=AES_S[(temp>>16)&255], b2=AES_S[(temp>>8)&255], b3=AES_S[temp&255];
            temp = ((uint32_t)b0<<24)|((uint32_t)b1<<16)|((uint32_t)b2<<8)|b3;
            temp ^= RCON[i/AES_NK] << 24;
        } else if (AES_NK > 6 && i % AES_NK == 4) {
            unsigned char b0=AES_S[temp>>24], b1=AES_S[(temp>>16)&255], b2=AES_S[(temp>>8)&255], b3=AES_S[temp&255];
            temp = ((uint32_t)b0<<24)|((uint32_t)b1<<16)|((uint32_t)b2<<8)|b3;
        }
        rk[i] = rk[i-AES_NK] ^ temp;
    }
}

static void aes_encrypt_block(const uint32_t rk[4*(AES_NR+1)], const unsigned char in[16], unsigned char out[16]) {
    unsigned char s[16], t[16];
    /* copy in column-major: s[col*4+row] = in[col*4+row] */
    memcpy(s, in, 16);
    /* AddRoundKey(0) */
    for (int c = 0; c < 4; c++) {
        s[c*4+0] ^= (unsigned char)(rk[c] >> 24);
        s[c*4+1] ^= (unsigned char)(rk[c] >> 16);
        s[c*4+2] ^= (unsigned char)(rk[c] >> 8);
        s[c*4+3] ^= (unsigned char)rk[c];
    }
    for (int r = 1; r < AES_NR; r++) {
        /* SubBytes */
        for (int i = 0; i < 16; i++) s[i] = AES_S[s[i]];
        /* ShiftRows: row j shifted left by j; t = shifted state (col-major) */
        /* state[col][row]: after shift, new[col][row] = old[(col+row)%4][row] */
        for (int col = 0; col < 4; col++) {
            for (int row = 0; row < 4; row++) {
                int ocol = (col + row) % 4;
                t[col*4+row] = s[ocol*4+row];
            }
        }
        /* MixColumns + AddRoundKey */
        for (int col = 0; col < 4; col++) {
            unsigned char a0=t[col*4+0], a1=t[col*4+1], a2=t[col*4+2], a3=t[col*4+3];
            unsigned char r0 = gf_mul(a0,2)^gf_mul(a1,3)^a2^a3;
            unsigned char r1 = a0^gf_mul(a1,2)^gf_mul(a2,3)^a3;
            unsigned char r2 = a0^a1^gf_mul(a2,2)^gf_mul(a3,3);
            unsigned char r3 = gf_mul(a0,3)^a1^a2^gf_mul(a3,2);
            s[col*4+0] = r0 ^ (unsigned char)(rk[r*4+col] >> 24);
            s[col*4+1] = r1 ^ (unsigned char)(rk[r*4+col] >> 16);
            s[col*4+2] = r2 ^ (unsigned char)(rk[r*4+col] >> 8);
            s[col*4+3] = r3 ^ (unsigned char)rk[r*4+col];
        }
    }
    /* final round: SubBytes, ShiftRows, AddRoundKey */
    for (int i = 0; i < 16; i++) s[i] = AES_S[s[i]];
    for (int col = 0; col < 4; col++) {
        for (int row = 0; row < 4; row++) {
            int ocol = (col + row) % 4;
            t[col*4+row] = s[ocol*4+row];
        }
    }
    for (int col = 0; col < 4; col++) {
        out[col*4+0] = t[col*4+0] ^ (unsigned char)(rk[AES_NR*4+col] >> 24);
        out[col*4+1] = t[col*4+1] ^ (unsigned char)(rk[AES_NR*4+col] >> 16);
        out[col*4+2] = t[col*4+2] ^ (unsigned char)(rk[AES_NR*4+col] >> 8);
        out[col*4+3] = t[col*4+3] ^ (unsigned char)rk[AES_NR*4+col];
    }
}

/* ==================================================================== GHASH / GCM */

static void gf128_mul(const unsigned char x[16], const unsigned char y[16], unsigned char out[16]) {
    unsigned char z[16] = {0};
    unsigned char v[16];
    memcpy(v, y, 16);
    for (int i = 0; i < 128; i++) {
        if (x[i>>3] & (0x80 >> (i&7))) {
            for (int j = 0; j < 16; j++) z[j] ^= v[j];
        }
        unsigned char lsb = v[15] & 1;
        for (int j = 15; j > 0; j--) v[j] = (v[j] >> 1) | (v[j-1] << 7);
        v[0] >>= 1;
        if (lsb) v[0] ^= 0xe1;
    }
    memcpy(out, z, 16);
}

static void ghash(const unsigned char h[16],
                  const unsigned char *aad, size_t alen,
                  const unsigned char *ct, size_t clen,
                  unsigned char out[16]) {
    unsigned char y[16] = {0};
    size_t n = (alen + 15) / 16;
    for (size_t i = 0; i < n; i++) {
        for (int j = 0; j < 16; j++)
            y[j] ^= (i*16+j < alen) ? aad[i*16+j] : 0;
        gf128_mul(y, h, y);
    }
    n = (clen + 15) / 16;
    for (size_t i = 0; i < n; i++) {
        for (int j = 0; j < 16; j++)
            y[j] ^= (i*16+j < clen) ? ct[i*16+j] : 0;
        gf128_mul(y, h, y);
    }
    unsigned char lenb[16] = {0};
    uint64_t al = (uint64_t)alen * 8, cl = (uint64_t)clen * 8;
    for (int i = 0; i < 8; i++) lenb[i] = (unsigned char)(al >> (56 - i*8));
    for (int i = 0; i < 8; i++) lenb[8+i] = (unsigned char)(cl >> (56 - i*8));
    for (int j = 0; j < 16; j++) y[j] ^= lenb[j];
    gf128_mul(y, h, y);
    memcpy(out, y, 16);
}

static void inc32(unsigned char ctr[16]) {
    for (int k = 15; k >= 12; k--) {
        ctr[k]++;
        if (ctr[k] != 0) break;
    }
}

/* AES-GCM decrypt: data = iv(12) || ct || tag(16). Returns 0 ok, -1 fail. */
static int gcm_decrypt(const unsigned char key[32],
                       const unsigned char *data, size_t dlen,
                       unsigned char *out, size_t *outlen) {
    if (dlen < 12 + 16) return -1;
    const unsigned char *iv = data;
    size_t clen = dlen - 12 - 16;
    const unsigned char *ct = data + 12;
    const unsigned char *tag = data + dlen - 16;

    uint32_t rk[4*(AES_NR+1)];
    aes_expand_key(key, rk);

    unsigned char h[16], zero[16] = {0};
    aes_encrypt_block(rk, zero, h);

    /* J0 = iv || 0x00000001 */
    unsigned char j0[16];
    memcpy(j0, iv, 12);
    j0[12]=0; j0[13]=0; j0[14]=0; j0[15]=1;

    /* expected tag = GHASH(H, AAD="", C) XOR AES_K(J0) */
    unsigned char g[16], keystream[16];
    ghash(h, NULL, 0, ct, clen, g);
    aes_encrypt_block(rk, j0, keystream);
    for (int j = 0; j < 16; j++) g[j] ^= keystream[j];

    if (memcmp(g, tag, 16) != 0) return -1;

    /* CTR decrypt: counters J0+1, J0+2, ... */
    unsigned char ctr[16];
    memcpy(ctr, j0, 16);
    for (size_t off = 0; off < clen; off += 16) {
        inc32(ctr);
        aes_encrypt_block(rk, ctr, keystream);
        size_t n = clen - off; if (n > 16) n = 16;
        for (size_t i = 0; i < n; i++) out[off+i] = ct[off+i] ^ keystream[i];
    }
    *outlen = clen;
    return 0;
}

/* AES-GCM encrypt: output = iv(12) || ct || tag(16). Caller supplies the
 * 12-byte iv. Returns 0 ok, -1 fail. Only used by the VIP ticket issuer. */
static int gcm_encrypt(const unsigned char key[32],
                       const unsigned char *iv,
                       const unsigned char *pt, size_t plen,
                       unsigned char *out, size_t *outlen) {
    uint32_t rk[4*(AES_NR+1)];
    aes_expand_key(key, rk);

    unsigned char h[16], zero[16] = {0};
    aes_encrypt_block(rk, zero, h);

    unsigned char j0[16];
    memcpy(j0, iv, 12);
    j0[12]=0; j0[13]=0; j0[14]=0; j0[15]=1;

    /* CTR encrypt: counters J0+1, J0+2, ... */
    unsigned char ctr[16], keystream[16];
    memcpy(ctr, j0, 16);
    for (size_t off = 0; off < plen; off += 16) {
        inc32(ctr);
        aes_encrypt_block(rk, ctr, keystream);
        size_t n = plen - off; if (n > 16) n = 16;
        for (size_t i = 0; i < n; i++) out[off+i] = pt[off+i] ^ keystream[i];
    }
    secure_zero(ctr, sizeof(ctr));

    /* tag = GHASH(H, AAD="", C) XOR AES_K(J0) */
    unsigned char g[16];
    ghash(h, NULL, 0, out, plen, g);
    aes_encrypt_block(rk, j0, keystream);
    for (int j = 0; j < 16; j++) g[j] ^= keystream[j];
    memcpy(out + plen, g, 16);

    memmove(out + 12, out, plen + 16); /* shift ct+tag after iv */
    memcpy(out, iv, 12);
    *outlen = 12 + plen + 16;

    secure_zero(j0, sizeof(j0));
    secure_zero(g, sizeof(g));
    secure_zero(keystream, sizeof(keystream));
    secure_zero(h, sizeof(h));
    secure_zero(rk, sizeof(rk));
    return 0;
}

/* ------------------------------------------------------------------ helpers */

static void to_hex(const unsigned char *in, size_t n, char *out) {
    static const char H[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) { out[i*2]=H[in[i]>>4]; out[i*2+1]=H[in[i]&15]; }
    out[n*2]=0;
}

static unsigned char *b64_decode(const char *in, size_t *out_len) {
    static signed char T[256]; static int init = 0;
    if (!init) {
        for (int i = 0; i < 256; i++) T[i] = -1;
        const char *std = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (int i = 0; i < 64; i++) T[(unsigned char)std[i]] = (signed char)i;
        T['-'] = 62; T['_'] = 63;
        init = 1;
    }
    size_t n = strlen(in);
    while (n > 0 && in[n-1] == '=') n--;
    if (n == 0) return NULL;
    size_t cap = n/4*3 + (n%4 ? n%4-1 : 0) + 1;
    unsigned char *out = (unsigned char *)malloc(cap);
    if (!out) return NULL;
    size_t o = 0, i = 0;
    while (i < n) {
        size_t rem = n - i;
        int a = T[(unsigned char)in[i]]; i++;
        int b = i<n ? T[(unsigned char)in[i]] : 0; i++;
        int c = i<n ? T[(unsigned char)in[i]] : 0; i++;
        int d = i<n ? T[(unsigned char)in[i]] : 0; i++;
        if (a<0||b<0||c<0||d<0) break;
        if (rem >= 4) {
            if (o<cap) out[o++]=(unsigned char)((a<<2)|(b>>4));
            if (o<cap) out[o++]=(unsigned char)(((b&15)<<4)|(c>>2));
            if (o<cap) out[o++]=(unsigned char)(((c&3)<<6)|d);
        } else {
            if (o<cap) out[o++]=(unsigned char)((a<<2)|(b>>4));
            if (rem == 3 && o<cap) out[o++]=(unsigned char)(((b&15)<<4)|(c>>2));
        }
    }
    *out_len = o;
    return out;
}

static char *b64_encode(const unsigned char *in, size_t n) {
    static const char T[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t olen = 4 * ((n + 2) / 3);
    char *out = (char *)malloc(olen + 1);
    if (!out) return NULL;
    size_t o = 0, i = 0;
    while (i + 3 <= n) {
        uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i+1] << 8) | in[i+2];
        out[o++] = T[(v >> 18) & 63];
        out[o++] = T[(v >> 12) & 63];
        out[o++] = T[(v >> 6) & 63];
        out[o++] = T[v & 63];
        i += 3;
    }
    size_t rem = n - i;
    if (rem == 1) {
        uint32_t v = ((uint32_t)in[i] << 16);
        out[o++] = T[(v >> 18) & 63];
        out[o++] = T[(v >> 12) & 63];
        out[o++] = '=';
        out[o++] = '=';
    } else if (rem == 2) {
        uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i+1] << 8);
        out[o++] = T[(v >> 18) & 63];
        out[o++] = T[(v >> 12) & 63];
        out[o++] = T[(v >> 6) & 63];
        out[o++] = '=';
    }
    out[o] = 0;
    return out;
}

/* The ONLY copies of the crypto material (split so `strings` shows fragments). */
/* Key-derivation constants decode from the scrambled tables at use time —
 * the plaintext never sits in .rodata. Derived bytes are identical to the
 * old literal-based builders, so existing envelopes stay decryptable. */
static void build_v3_pepper(char out[64]) { ob_decode(OB_V3_PEPPER, OB_V3_PEPPER_LEN, OB_V3_PEPPER_KEY, out, 64); }
static void build_v2_seed(char out[96])  { ob_decode(OB_V2_SEED, OB_V2_SEED_LEN, OB_V2_SEED_KEY, out, 96); }
static void build_v1_key(char out[96])   { ob_decode(OB_V1_KEY, OB_V1_KEY_LEN, OB_V1_KEY_KEY, out, 96); }
static void build_vip_seed(char out[96]) { ob_decode(OB_VIP_SEED, OB_VIP_SEED_LEN, OB_VIP_SEED_KEY, out, 96); }

static int hex_eq_icase(const char *a, const char *b) {
    size_t i = 0;
    for (;;) {
        char ca = a[i], cb = b[i];
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
        if (ca != cb) return 0;
        if (ca == 0) return 1;
        i++;
    }
}

/* ------------------------------------------------- runtime self-protection
 *
 * Watchdog thread: detects ptrace attach (Frida-style) and known injection
 * artifacts in our own /proc entries. Strikes are counted — the app does not
 * announce itself — after 2 strikes the decrypt gate goes permanently dark
 * (poisoned), after 3 the process exits quietly on a random delay. Reads use
 * direct syscalls so libc PLT hooks never see them. Syscall wrappers provide
 * both __aarch64__ (arm64) and __arm__ (armeabi-v7a, 32-bit branch) variants.
 */

static volatile int g_strikes = 0;
static volatile int g_poisoned = 0;

static long sys_openat(int dirfd, const char *path, int flags, int mode) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = 56; /* __NR_openat */
    register long x0 __asm__("x0") = (long)dirfd;
    register long x1 __asm__("x1") = (long)path;
    register long x2 __asm__("x2") = (long)flags;
    register long x3 __asm__("x3") = (long)mode;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
#elif defined(__arm__)
    register long r7 __asm__("r7") = 322; /* __NR_openat (ARM EABI) */
    register long r0 __asm__("r0") = (long)dirfd;
    register long r1 __asm__("r1") = (long)path;
    register long r2 __asm__("r2") = (long)flags;
    register long r3 __asm__("r3") = (long)mode;
    __asm__ volatile("svc #0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2), "r"(r3) : "memory");
    return r0;
#else
    return -1;
#endif
}

static long sys_read(long fd, void *buf, size_t n) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = 63; /* __NR_read */
    register long x0 __asm__("x0") = fd;
    register long x1 __asm__("x1") = (long)buf;
    register long x2 __asm__("x2") = (long)n;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
#elif defined(__arm__)
    register long r7 __asm__("r7") = 3; /* __NR_read (ARM EABI) */
    register long r0 __asm__("r0") = fd;
    register long r1 __asm__("r1") = (long)buf;
    register long r2 __asm__("r2") = (long)n;
    __asm__ volatile("svc #0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
#else
    return -1;
#endif
}

static long sys_close(long fd) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = 57; /* __NR_close */
    register long x0 __asm__("x0") = fd;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
    return x0;
#elif defined(__arm__)
    register long r7 __asm__("r7") = 6; /* __NR_close (ARM EABI) */
    register long r0 __asm__("r0") = fd;
    __asm__ volatile("svc #0" : "+r"(r0) : "r"(r7) : "memory");
    return r0;
#else
    return -1;
#endif
}

/* ================================================= integrity mesh (libapp.so)
 *
 * Binds the Dart AOT blob to this library: hash libapp.so (the on-disk copy in
 * the same nativeLibraryDir) and compare to the CI-baked per-ABI macro. A
 * patched/replaced libapp.so then fails integrity and feeds, exactly like a
 * re-signed cert. Cached — the ~10MB hash runs at most once per process.
 *
 * The directory is discovered from /proc/self/maps, which lists the absolute
 * path of THIS mapping; libapp.so sits beside libsnapdarkcrypto.so (AGP extracts
 * all native libs to applicationInfo.nativeLibraryDir).
 */
static int libapp_mesh_ok(void) {
#ifdef SNAPDARK_HAVE_LIBAPP_SHA256
    static int g_result = -1; /* -1 uncomputed, 0 fail, 1 pass */
    if (g_result >= 0) return g_result;
    if (SNAPDARK_EXPECTED_LIBAPP_SHA256[0] == 0 ||
        strcmp(SNAPDARK_EXPECTED_LIBAPP_SHA256, "none") == 0) {
        g_result = 1;
        return 1;
    }

    long fd = sys_openat(-100, "/proc/self/maps", 0, 0);
    if (fd < 0) { g_result = 1; return 1; } /* cannot inspect -> don't gate a legit install off */
    char dir[768];
    dir[0] = 0;
    {
        char buf[8192];
        size_t have = 0;
        static const char needle[] = "libsnapdarkcrypto.so";
        const size_t nlen = sizeof(needle) - 1;
        for (;;) {
            long r = sys_read(fd, buf + have, sizeof(buf) - have);
            if (r <= 0) break;
            have += (size_t)r;
            for (size_t i = 0; i + nlen <= have; i++) {
                if (memcmp(buf + i, needle, nlen) == 0) {
                    size_t start = i;
                    while (start > 0 && buf[start - 1] != '/') start--;
                    if (start > 0 && buf[start - 1] == '/') {
                        size_t dir_len = start - 1; /* drop the trailing '/' */
                        if (dir_len > sizeof(dir) - 1) dir_len = sizeof(dir) - 1;
                        memcpy(dir, buf, dir_len);
                        dir[dir_len] = 0;
                        break;
                    }
                }
            }
            if (dir[0] != 0) break;
            if (have > nlen) {
                memmove(buf, buf + have - nlen, nlen);
                have = nlen;
            }
        }
        secure_zero(buf, sizeof(buf));
    }
    sys_close(fd);
    if (dir[0] != '/' || dir[0] == 0) { g_result = 1; return 1; } /* odd mapping — gate stays open */

    char path[896];
    snprintf(path, sizeof(path), "%s/libapp.so", dir);
    long afd = sys_openat(-100, path, 0, 0);
    if (afd < 0) { g_result = 1; return 1; } /* extracted libapp not found (stripped install) -> open */
    sha256_ctx c;
    sha256_init(&c);
    {
        unsigned char chunk[4096];
        for (;;) {
            long r = sys_read(afd, chunk, sizeof(chunk));
            if (r <= 0) break;
            sha256_update(&c, chunk, (size_t)r);
        }
        secure_zero(chunk, sizeof(chunk));
    }
    sys_close(afd);
    unsigned char digest[32];
    sha256_final(&c, digest);
    static const char H[] = "0123456789abcdef";
    char hex[65];
    for (int i = 0; i < 32; i++) {
        hex[i * 2] = H[digest[i] >> 4];
        hex[i * 2 + 1] = H[digest[i] & 15];
    }
    hex[64] = 0;
    int ok = hex_eq_icase(hex, SNAPDARK_EXPECTED_LIBAPP_SHA256);
    secure_zero(digest, sizeof(digest));
    g_result = ok ? 1 : 0;
    return g_result;
#else
    (void)0;
    return 1;
#endif
}

/* Read a /proc file and report whether `needle` (already decoded) appears. */
static int proc_contains(const char *path, const char *needle, size_t nlen) {
    if (nlen == 0) return 0;
    long fd = sys_openat(-100 /* AT_FDCWD */, path, 0 /* O_RDONLY */, 0);
    if (fd < 0) return 0;
    char buf[4096];
    size_t have = 0;
    int found = 0;
    for (;;) {
        long r = sys_read(fd, buf + have, sizeof(buf) - have);
        if (r <= 0) break;
        have += (size_t)r;
        /* scan the filled window for the needle */
        for (size_t i = 0; i + nlen <= have; i++) {
            size_t j = 0;
            while (j < nlen && buf[i + j] == needle[j]) j++;
            if (j == nlen) { found = 1; break; }
        }
        if (found) break;
        /* keep the tail for across-chunk matches */
        if (have > nlen) {
            memmove(buf, buf + have - nlen, nlen);
            have = nlen;
        }
    }
    secure_zero(buf, sizeof(buf));
    sys_close(fd);
    return found;
}

/* /proc/self/status: parse TracerPid: — non-zero means someone is attached. */
static int tracer_attached(void) {
    long fd = sys_openat(-100, "/proc/self/status", 0, 0);
    if (fd < 0) return 0;
    char buf[4096];
    size_t have = 0;
    int result = 0;
    for (;;) {
        long r = sys_read(fd, buf + have, sizeof(buf) - have);
        if (r <= 0) break;
        have += (size_t)r;
    }
    char needle[16];
    ob_decode(OB_TRACER, OB_TRACER_LEN, OB_TRACER_KEY, needle, sizeof(needle));
    size_t nlen = OB_TRACER_LEN;
    for (size_t i = 0; i + nlen < have; i++) {
        size_t j = 0;
        while (j < nlen && buf[i + j] == needle[j]) j++;
        if (j == nlen) {
            size_t k = i + nlen;
            while (k < have && (buf[k] == ' ' || buf[k] == '\t')) k++;
            int pid = 0;
            while (k < have && buf[k] >= '0' && buf[k] <= '9') {
                pid = pid * 10 + (buf[k] - '0');
                k++;
            }
            result = (pid != 0);
            break;
        }
    }
    secure_zero(buf, sizeof(buf));
    secure_zero(needle, sizeof(needle));
    sys_close(fd);
    return result;
}

static void *watchdog_thread(void *arg) {
    (void)arg;
    unsigned seed = 0x53534921u;
    for (;;) {
        seed = seed * 1664525u + 1013904223u;
        int sleepMs = 3000 + (int)(seed % 6000u); /* jittered 3–9 s */
        struct timespec ts;
        ts.tv_sec = sleepMs / 1000;
        ts.tv_nsec = (long)(sleepMs % 1000) * 1000000L;
        nanosleep(&ts, NULL);

        int hit = 0;
        if (tracer_attached()) hit++;

        char needle[24];
        if (!hit || g_strikes < 3) {
            if (proc_contains("/proc/self/maps", (ob_decode(OB_N_FRIDA, OB_N_FRIDA_LEN, OB_N_FRIDA_KEY, needle, sizeof(needle)), needle), OB_N_FRIDA_LEN)) hit++;
            if (proc_contains("/proc/self/maps", (ob_decode(OB_N_GADGET, OB_N_GADGET_LEN, OB_N_GADGET_KEY, needle, sizeof(needle)), needle), OB_N_GADGET_LEN)) hit++;
            if (proc_contains("/proc/self/maps", (ob_decode(OB_N_GUMJS, OB_N_GUMJS_LEN, OB_N_GUMJS_KEY, needle, sizeof(needle)), needle), OB_N_GUMJS_LEN)) hit++;
            if (proc_contains("/proc/self/maps", (ob_decode(OB_N_LINJECT, OB_N_LINJECT_LEN, OB_N_LINJECT_KEY, needle, sizeof(needle)), needle), OB_N_LINJECT_LEN)) hit++;
            if (proc_contains("/proc/self/maps", (ob_decode(OB_N_PFRIDA, OB_N_PFRIDA_LEN, OB_N_PFRIDA_KEY, needle, sizeof(needle)), needle), OB_N_PFRIDA_LEN)) hit++;
        }
        secure_zero(needle, sizeof(needle));

        if (hit) {
            g_strikes += hit;
            if (g_strikes >= 2) g_poisoned = 1; /* gate goes dark, silently */
            if (g_strikes >= 3) {
                /* quiet exit after a random delay — never an instant crash
                 * that tells the attacker which check fired */
                seed = seed * 1664525u + 1013904223u;
                int delayS = 20 + (int)(seed % 40u);
                struct timespec die;
                die.tv_sec = delayS;
                die.tv_nsec = 0;
                nanosleep(&die, NULL);
                _exit(0);
            }
        }
    }
    return NULL;
}

/* ---------------------------------------------------------------- JNI */

/* JNI entry points are registered manually from JNI_OnLoad under opaque
 * static symbols — the exported table of this .so contains JNI_OnLoad and
 * nothing else (see snapdark.map), so jadx/ghidra symbol maps find no
 * Java_com_snapdark_tunnel_* anchors at all. */

static jstring n_cert_sha(JNIEnv *env, jobject thiz, jbyteArray cert) {
    (void)thiz;
    jsize len = cert ? (*env)->GetArrayLength(env, cert) : 0;
    if (len <= 0) return (*env)->NewStringUTF(env, "");
    jbyte *bytes = (*env)->GetByteArrayElements(env, cert, NULL);
    if (!bytes) return (*env)->NewStringUTF(env, "");
    char hex[65];
    sha256_hex((const unsigned char *)bytes, (size_t)len, hex);
    (*env)->ReleaseByteArrayElements(env, cert, bytes, JNI_ABORT);
    return (*env)->NewStringUTF(env, hex);
}

/*
 * Signature gate for callers that only need the yes/no: JNI_TRUE when the
 * baked hash is blank (gate off) or the runtime cert hash matches it. The
 * comparison never leaves this library.
 */
static jboolean n_integrity_ok(JNIEnv *env, jobject thiz, jbyteArray cert) {
    (void)thiz;
    if (g_poisoned) return JNI_FALSE;
    if (!libapp_mesh_ok()) return JNI_FALSE;
    if (SNAPDARK_EXPECTED_CERT_SHA256[0] == 0) return JNI_TRUE;
    jsize len = cert ? (*env)->GetArrayLength(env, cert) : 0;
    if (len <= 0) return JNI_FALSE;
    jbyte *bytes = (*env)->GetByteArrayElements(env, cert, NULL);
    if (!bytes) return JNI_FALSE;
    char hex[65];
    sha256_hex((const unsigned char *)bytes, (size_t)len, hex);
    (*env)->ReleaseByteArrayElements(env, cert, bytes, JNI_ABORT);
    return hex_eq_icase(hex, SNAPDARK_EXPECTED_CERT_SHA256) ? JNI_TRUE : JNI_FALSE;
}

/*
 * Baked release-cert gate for callers that already hold the lowercase hex of
 * the runtime signing cert (n_vip_issue / n_vip_verify). Returns 1 when the
 * gate is off (no baked hash, i.e. local debug builds) or the hash matches.
 * A re-signed build therefore cannot mint OR verify a ticket, so the failure
 * surfaces at unlock time instead of as a silent connect-time resolve error.
 */
static int cert_hex_baked_ok(const char *certHex) {
    if (SNAPDARK_EXPECTED_CERT_SHA256[0] == 0) return 1;
    return certHex != NULL && hex_eq_icase(certHex, SNAPDARK_EXPECTED_CERT_SHA256);
}

/*
 * Single gate + decrypt entry: signature comparison, version detection, key
 * derivation and AES-GCM/XOR all happen here, native-only.
 *   nativeDecrypt(expectedSha256, certBytes, body) -> plaintext JSON or null
 */
static jstring n_decrypt(JNIEnv *env, jobject thiz,
                         jstring expected, jbyteArray cert,
                         jstring body) {
    (void)thiz;
    if (g_poisoned) return NULL;
    if (!body || !cert) return NULL;
    if (!libapp_mesh_ok()) return NULL; /* Dart AOT blob drifted from the baked mesh */

    const char *b = (*env)->GetStringUTFChars(env, body, NULL);
    if (!b) return NULL;

    jsize clen = (*env)->GetArrayLength(env, cert);
    jbyte *cbytes = (*env)->GetByteArrayElements(env, cert, NULL);
    if (!cbytes) { (*env)->ReleaseStringUTFChars(env, body, b); return NULL; }

    char certHex[65];
    sha256_hex((const unsigned char *)cbytes, (size_t)clen, certHex);
    (*env)->ReleaseByteArrayElements(env, cert, cbytes, JNI_ABORT);

    /* integrity gate: re-signed clone gets a different cert hash -> null.
     * An empty/absent `expected` argument means "use the baked-in hash". */
    const char *expParam = NULL;
    if (expected != NULL) expParam = (*env)->GetStringUTFChars(env, expected, NULL);
    const char *exp = (expParam && expParam[0] != 0) ? expParam : SNAPDARK_EXPECTED_CERT_SHA256;
    int gateFail = (exp[0] != 0) && !hex_eq_icase(certHex, exp);
    if (expParam) (*env)->ReleaseStringUTFChars(env, expected, expParam);
    if (gateFail) {
        (*env)->ReleaseStringUTFChars(env, body, b);
        return NULL;
    }

    jstring result = NULL;

    char p3[16], p2[16], p1[16];
    ob_decode(OB_V3_PREFIX, OB_V3_PREFIX_LEN, OB_V3_PREFIX_KEY, p3, sizeof(p3));
    ob_decode(OB_V2_PREFIX, OB_V2_PREFIX_LEN, OB_V2_PREFIX_KEY, p2, sizeof(p2));
    ob_decode(OB_V1_PREFIX, OB_V1_PREFIX_LEN, OB_V1_PREFIX_KEY, p1, sizeof(p1));

    if (strncmp(b, p3, 10) == 0) {
        char pepper[64];
        build_v3_pepper(pepper);
        size_t seedLen = strlen(certHex) + 1 + strlen(pepper);
        char *seed = (char *)malloc(seedLen + 1);
        if (seed) {
            snprintf(seed, seedLen + 1, "%s:%s", certHex, pepper);
            unsigned char key[32];
            sha256((const unsigned char *)seed, strlen(seed), key);
            secure_zero(seed, seedLen + 1);
            secure_zero(pepper, sizeof(pepper));
            free(seed);
            size_t rawLen = 0;
            unsigned char *raw = b64_decode(b + 10, &rawLen);
            if (raw) {
                unsigned char *plain = (unsigned char *)malloc(rawLen + 1);
                size_t plen = 0;
                if (plain && gcm_decrypt(key, raw, rawLen, plain, &plen) == 0) {
                    plain[plen] = 0;
                    result = (*env)->NewStringUTF(env, (const char *)plain);
                }
                free(plain);
                free(raw);
            }
            secure_zero(key, sizeof(key));
        }
    } else if (strncmp(b, p2, 10) == 0) {
        char seed[96];
        build_v2_seed(seed);
        unsigned char key[32];
        sha256((const unsigned char *)seed, strlen(seed), key);
        secure_zero(seed, sizeof(seed));
        size_t rawLen = 0;
        unsigned char *raw = b64_decode(b + 10, &rawLen);
        if (raw) {
            unsigned char *plain = (unsigned char *)malloc(rawLen + 1);
            size_t plen = 0;
            if (plain && gcm_decrypt(key, raw, rawLen, plain, &plen) == 0) {
                plain[plen] = 0;
                result = (*env)->NewStringUTF(env, (const char *)plain);
            }
            free(plain);
            free(raw);
        }
        secure_zero(key, sizeof(key));
    } else if (strncmp(b, p1, 10) == 0) {
        char key[96];
        build_v1_key(key);
        size_t keyLen = strlen(key);
        size_t rawLen = 0;
        unsigned char *raw = b64_decode(b + 10, &rawLen);
        if (raw) {
            unsigned char *plain = (unsigned char *)malloc(rawLen + 1);
            if (plain) {
                for (size_t i = 0; i < rawLen; i++) plain[i] = raw[i] ^ key[i % keyLen];
                plain[rawLen] = 0;
                result = (*env)->NewStringUTF(env, (const char *)plain);
                free(plain);
            }
            free(raw);
        }
        secure_zero(key, sizeof(key));
    }
    secure_zero(p3, sizeof(p3));
    secure_zero(p2, sizeof(p2));
    secure_zero(p1, sizeof(p1));
    secure_zero(certHex, sizeof(certHex));

    (*env)->ReleaseStringUTFChars(env, body, b);
    return result;
}

/* ------------------------------------------------------------------ VIP unlock
 *
 * cert-bound AES-256-GCM unlock ticket so a root editor who rewrites the plain
 * `id|epoch` SharedPreferences line cannot mint VIP access. Envelope is
 * `sensei:vip:` + base64(iv|ct|tag) with plaintext `vip1|<configId>|<issued>|<expires>`.
 * Key = SHA-256(certHex + ":" + VIP_SEED): bound to the installed certificate,
 * so a re-signed clone cannot forge tickets and tickets minted under a
 * different signature cannot verify. Native-only seed — never in the DEX.
 */

static int read_random_bytes(unsigned char *buf, size_t n) {
    ssize_t got = 0;
    int fd = (int)sys_openat(-100 /* AT_FDCWD */, "/dev/urandom", 0 /* O_RDONLY */, 0);
    if (fd < 0) return -1;
    while (got < (ssize_t)n) {
        ssize_t r = (ssize_t)sys_read(fd, buf + got, (size_t)(n - got));
        if (r <= 0) break;
        got += r;
    }
    sys_close(fd);
    return (got == (ssize_t)n) ? 0 : -1;
}

/* issueVipTicket helper: derive the cert-bound ticket key into key[32]. */
/* Derives the cert-bound ticket key. Returns 0 on success, -1 on allocation
 * failure — callers MUST check, otherwise key[] stays uninitialized and the
 * ticket is encrypted under garbage. */
static int vip_ticket_key(const char *certHex, unsigned char key[32]) {
    char seed[96];
    build_vip_seed(seed);
    size_t seedLen = strlen(certHex) + 1 + strlen(seed);
    char *kseed = (char *)malloc(seedLen + 1);
    if (!kseed) { secure_zero(seed, sizeof(seed)); return -1; }
    snprintf(kseed, seedLen + 1, "%s:%s", certHex, seed);
    sha256((const unsigned char *)kseed, seedLen, key);
    secure_zero(seed, sizeof(seed));
    secure_zero(kseed, seedLen + 1);
    free(kseed);
    return 0;
}

/*
 * nativeVipIssue(cert, configId, durationMs) -> "sensei:vip:..." or NULL.
 * Issues a cert-bound AES-256-GCM unlock ticket valid for durationMs.
 */
static jstring n_vip_issue(JNIEnv *env, jobject thiz,
                           jbyteArray cert, jstring configId,
                           jlong durationMs) {
    (void)thiz;
    if (g_poisoned) return NULL;
    if (!cert || !configId) return NULL;
    if (!libapp_mesh_ok()) return NULL;

    jsize clen = (*env)->GetArrayLength(env, cert);
    if (clen <= 0) return NULL;
    jbyte *cbytes = (*env)->GetByteArrayElements(env, cert, NULL);
    if (!cbytes) return NULL;
    char certHex[65];
    sha256_hex((const unsigned char *)cbytes, (size_t)clen, certHex);
    (*env)->ReleaseByteArrayElements(env, cert, cbytes, JNI_ABORT);
    if (!cert_hex_baked_ok(certHex)) return NULL;

    const char *cfg = (*env)->GetStringUTFChars(env, configId, NULL);
    if (!cfg) return NULL;

    /* lifetime sanity clamp: 1 hour .. 30 days */
    long long dur = (long long)durationMs;
    if (dur < 3600LL * 1000) dur = 3600LL * 1000;
    if (dur > 30LL * 24 * 3600 * 1000) dur = 30LL * 24 * 3600 * 1000;

    long long nowMs = (long long)time(NULL) * 1000LL;
    long long expiresMs = nowMs + dur;

    if (strchr(cfg, '|') != NULL) { /* configId must not break the framing */
        (*env)->ReleaseStringUTFChars(env, configId, cfg);
        return NULL;
    }
    /* Cap the id length so the framed plaintext always fits the raw buffer
     * below with room for the 12-byte IV and 16-byte GCM tag. Without this a
     * long id would make gcm_encrypt write past the end of raw[]. */
    if (strlen(cfg) > 256) {
        (*env)->ReleaseStringUTFChars(env, configId, cfg);
        return NULL;
    }

    size_t plen = strlen(cfg) + 64;
    char *plain = (char *)malloc(plen);
    if (!plain) { (*env)->ReleaseStringUTFChars(env, configId, cfg); return NULL; }
    snprintf(plain, plen, "vip1|%s|%lld|%lld", cfg, nowMs, expiresMs);
    size_t plainLen = strlen(plain);
    (*env)->ReleaseStringUTFChars(env, configId, cfg);

    unsigned char key[32];
    if (vip_ticket_key(certHex, key) != 0) {
        secure_zero(plain, plainLen);
        free(plain);
        return NULL;
    }
    secure_zero(certHex, sizeof(certHex));

    unsigned char raw[4096];
    size_t rawLen = 0;
    unsigned char iv[12];
    jstring result = NULL;
    /* Check the ciphertext budget BEFORE encrypting: gcm_encrypt writes
     * rawLen bytes unconditionally, so a post-hoc rawLen check is too late. */
    int fits = (plainLen + 12 + 16) <= sizeof(raw);
    if (fits && read_random_bytes(iv, sizeof(iv)) == 0) {
        if (gcm_encrypt(key, iv, (const unsigned char *)plain, plainLen,
                        raw, &rawLen) == 0 && rawLen <= sizeof(raw)) {
            char *b64 = b64_encode(raw, rawLen);
            if (b64) {
                char pfx[16];
                ob_decode(OB_VIP_PREFIX, OB_VIP_PREFIX_LEN, OB_VIP_PREFIX_KEY, pfx, sizeof(pfx));
                size_t outLen = strlen(pfx) + strlen(b64) + 1;
                char *out = (char *)malloc(outLen);
                if (out) {
                    snprintf(out, outLen, "%s%s", pfx, b64);
                    result = (*env)->NewStringUTF(env, out);
                    secure_zero(out, outLen);
                    free(out);
                }
                secure_zero(b64, strlen(b64));
                free(b64);
            }
        }
    }
    secure_zero(iv, sizeof(iv));
    secure_zero(raw, sizeof(raw));
    secure_zero(plain, plainLen);
    secure_zero(key, sizeof(key));
    free(plain);
    return result;
}

/*
 * nativeVipVerify(cert, ticket, configId) -> expiresMs (long) or -1.
 * Decrypts + authenticates the ticket, checks it names this configId and is
 * still in the future per the auto-issued lifetime. Re-signed builds fail the
 * cert-bound key, tampered prefs fail the GCM tag, expired tickets return -1.
 */
static jlong n_vip_verify(JNIEnv *env, jobject thiz,
                          jbyteArray cert, jstring ticket,
                          jstring configId) {
    (void)thiz;
    if (g_poisoned) return -1;
    if (!cert || !ticket || !configId) return -1;
    if (!libapp_mesh_ok()) return -1;

    jsize clen = (*env)->GetArrayLength(env, cert);
    if (clen <= 0) return -1;
    jbyte *cbytes = (*env)->GetByteArrayElements(env, cert, NULL);
    if (!cbytes) return -1;
    char certHex[65];
    sha256_hex((const unsigned char *)cbytes, (size_t)clen, certHex);
    (*env)->ReleaseByteArrayElements(env, cert, cbytes, JNI_ABORT);
    if (!cert_hex_baked_ok(certHex)) return -1;

    const char *b = (*env)->GetStringUTFChars(env, ticket, NULL);
    const char *cfg = (*env)->GetStringUTFChars(env, configId, NULL);
    if (!b || !cfg) {
        if (b) (*env)->ReleaseStringUTFChars(env, ticket, b);
        if (cfg) (*env)->ReleaseStringUTFChars(env, configId, cfg);
        return -1;
    }

    jlong result = -1;
    char pfx[16];
    ob_decode(OB_VIP_PREFIX, OB_VIP_PREFIX_LEN, OB_VIP_PREFIX_KEY, pfx, sizeof(pfx));
    if (strncmp(b, pfx, OB_VIP_PREFIX_LEN) == 0) {
        unsigned char key[32];
        if (vip_ticket_key(certHex, key) == 0) {
        size_t rawLen = 0;
        unsigned char *raw = b64_decode(b + OB_VIP_PREFIX_LEN, &rawLen);
        if (raw) {
            unsigned char *plain = (unsigned char *)malloc(rawLen + 1);
            size_t plen = 0;
            if (plain && gcm_decrypt(key, raw, rawLen, plain, &plen) == 0) {
                plain[plen] = 0;
                /* "vip1|<configId>|<issued>|<expires>" */
                const char *p = (const char *)plain;
                if (strncmp(p, "vip1|", 5) == 0) {
                    const char *c2 = p + 5;
                    const char *se = strchr(c2, '|');
                    if (se && (size_t)(se - c2) == strlen(cfg) &&
                        strncmp(c2, cfg, (size_t)(se - c2)) == 0) {
                        long long issued = atoll(se + 1);
                        const char *se2 = strchr(se + 1, '|');
                        if (se2) {
                            long long expires = atoll(se2 + 1);
                            long long nowMs = (long long)time(NULL) * 1000LL;
                            if (issued > 0 && expires > issued && nowMs < expires) {
                                result = (jlong)expires;
                            }
                        }
                    }
                }
            }
            secure_zero(raw, rawLen);
            free(raw);
            secure_zero(plain, plen);
            free(plain);
        }
        secure_zero(key, sizeof(key));
        }
    }
    secure_zero(pfx, sizeof(pfx));
    secure_zero((void *)b, strlen(b));
    (*env)->ReleaseStringUTFChars(env, ticket, b);
    (*env)->ReleaseStringUTFChars(env, configId, cfg);
    secure_zero(certHex, sizeof(certHex));
    return result;
}

/* JNI_OnLoad: the ONLY exported symbol. Registers the three native methods
 * under their (R8-kept) Java names, points them at the opaque statics above,
 * and starts the anti-instrumentation watchdog. */
__attribute__((visibility("default")))
jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;

    /* FindClass inside JNI_OnLoad resolves against the classloader of the
     * caller — System.loadLibrary runs from AppSecurity's init, so the app
     * class is visible here. */
    jclass cls = (*env)->FindClass(env, "com/snapdark/tunnel/AppSecurity");
    if (!cls) return JNI_ERR;

    static const JNINativeMethod methods[] = {
        {"nativeCertSha256", "([B)Ljava/lang/String;", (void *)&n_cert_sha},
        {"nativeIntegrityOk", "([B)Z", (void *)&n_integrity_ok},
        {"nativeDecrypt", "(Ljava/lang/String;[BLjava/lang/String;)Ljava/lang/String;", (void *)&n_decrypt},
        {"nativeVipIssue", "([BLjava/lang/String;J)Ljava/lang/String;", (void *)&n_vip_issue},
        {"nativeVipVerify", "([BLjava/lang/String;Ljava/lang/String;)J", (void *)&n_vip_verify},
    };
    if ((*env)->RegisterNatives(env, cls, methods,
                                sizeof(methods) / sizeof(methods[0])) != JNI_OK) {
        return JNI_ERR;
    }

    pthread_t t;
    if (pthread_create(&t, NULL, watchdog_thread, NULL) == 0) {
        pthread_detach(t);
    }
    return JNI_VERSION_1_6;
}
