#!/usr/bin/env python3
"""Audit + rotate the obfuscated seed arrays in senseicrypto.c.

STEP 1 (audit): decode every OB_* XOR array and print the plaintexts.
STEP 2 (rotate, --rotate): rewrite the arrays/lengths for the new seeds so
they stay byte-identical with admin/src/crypto.js (V2_SEED / VIP_SEED /
V3_PEPPER_DEFAULT). Verifies by re-decoding after the write.

The XOR scheme is: plaintext[i] = array[i] ^ key  (key in the #define).
"""
import re
import sys

C_FILE = "/root/back-tunnel/app/android/app/src/main/cpp/snapdarkcrypto.c"

# New shared secrets — MUST match admin/src/crypto.js after rotation.
# (Wire-format prefixes like `sensei:v2:` and the anti-frida needles are
# format identifiers, NOT secrets — they stay as-is.)
NEW = {
    "OB_V2_SEED": ("ArmanTunnel:Armanmiah2026:v2", 0x37),
    "OB_VIP_SEED": ("ArmanTunnel:Armanmiah2026:vip", 0x5E),
    "OB_V1_KEY": ("ArmanTunnel:Armanmiah2026", 0x6E),
    "OB_V3_PEPPER": ("arman::cfg::v3::2026", 0x5A),
}

ARRAY_RE = re.compile(
    r"static const unsigned char (OB_[A-Z0-9_]+)\[\] = \{([^}]*)\};")
KEY_RE = re.compile(r"#define (OB_[A-Z0-9_]+)_KEY (0x[0-9A-Fa-f]+|\d+)")
LEN_RE = re.compile(r"#define (OB_[A-Z0-9_]+)_LEN (\d+)")


def parse(src):
    arrays = {m.group(1): bytes(int(x, 16) for x in re.findall(r"0x[0-9A-Fa-f]+", m.group(2)))
              for m in ARRAY_RE.finditer(src)}
    keys = {m.group(1): int(m.group(2), 0) for m in KEY_RE.finditer(src)}
    lens = {m.group(1): int(m.group(2)) for m in LEN_RE.finditer(src)}
    return arrays, keys, lens


def decode(arr, key):
    return bytes(b ^ key for b in arr).split(b"\x00")[0].decode("utf-8", "replace")


def fmt_array(name, data, key):
    hexes = ", ".join(f"0x{b:02x}" for b in data)
    return f"static const unsigned char {name}[] = {{{hexes}}};"


def main():
    src = open(C_FILE).read()
    arrays, keys, lens = parse(src)
    print("=== AUDIT: obfuscated arrays in senseicrypto.c ===")
    ok = True
    for name, arr in arrays.items():
        key = keys.get(name)
        if key is None:
            print(f"  {name}: (no key define found) len={len(arr)}")
            continue
        pt = decode(arr, key)
        declared = lens.get(name)
        flag = "" if declared == len(arr) else f"  !! LEN MISMATCH declared={declared}"
        print(f"  {name} key=0x{key:02x} len={len(arr)} → {pt!r}{flag}")

    if "--rotate" not in sys.argv:
        return 0

    print("\n=== ROTATE ===")
    for name, (plain, key) in NEW.items():
        if name not in arrays:
            print(f"  !! {name} not found — aborting")
            return 1
        if keys.get(name) != key:
            print(f"  !! {name} key is 0x{keys.get(name, 0):02x}, expected 0x{key:02x} — aborting")
            return 1
        new_bytes = bytes(ord(c) ^ key for c in plain)
        arr_re = re.compile(
            r"(static const unsigned char " + name + r"\[\] = \{)[^}]*(\};)")
        src, n = arr_re.subn(lambda m: m.group(1) + ", ".join(f"0x{b:02x}" for b in new_bytes) + m.group(2), src, count=1)
        if n != 1:
            print(f"  !! failed to rewrite {name} array")
            return 1
        len_re = re.compile(r"(#define " + name + r"_LEN )\d+")
        src, n = len_re.subn(lambda m: m.group(1) + str(len(new_bytes)), src, count=1)
        if n != 1:
            print(f"  !! failed to rewrite {name} LEN")
            return 1
        print(f"  ✓ {name} → {plain!r} (len {len(new_bytes)})")

    open(C_FILE, "w").write(src)

    print("\n=== VERIFY (re-decode after write) ===")
    arrays, keys, lens = parse(open(C_FILE).read())
    for name, (plain, key) in NEW.items():
        got = decode(arrays[name], keys[name])
        good = got == plain and lens[name] == len(plain)
        ok &= good
        print(f"  {'✓' if good else '✗'} {name} = {got!r} (len {lens[name]})")
    print("\nRESULT:", "ALL SEEDS MATCH" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
