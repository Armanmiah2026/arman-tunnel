library;

import 'dart:convert';
import 'dart:typed_data';

/// DarkTunnel `.dark` locked-config codec — pure Dart, no dependencies.
///
/// Wire format (mirrors the reverse-engineered DarkTunnel encryptor):
///
///   darktunnel://<urlsafe_b64(json, no padding)>
///     json = {type, name, countryIso?, <x>TunnelConfig: <visible decoy>,
///             encryptedLockedConfig: urlsafe_b64(
///               AES-256-CFB128(OUTER_KEY, IV) of msgpack({
///                 LockedAppConfig: {VersionCode, VersionName, Message,
///                     ConnectedMessage, Password(96B), ExpiredAtTimestamp,
///                     HardwareIdList, TunnelType, IsSshLocked},
///                 EncryptedLockedConfig: AES-192-CFB128(INNER_KEY, IV) of
///                     msgpack(inner)}))}
///
///   inner (VLESS/VMESS/TROJAN/custom):
///     {V2RayConfig: {IsEncrypted: true, IsInjectModeEnabled: bool,
///        EncryptedConfig: AES-CFB(INNER)(xray JSON string with $TOKENS)}}
///   inner (SSH/SSH_DNSTT):
///     {InjectConfig: {IsEncrypted: true, EncryptedMode, EncryptedProxyHost,
///        EncryptedProxyPort, EncryptedServerNameIndication, EncryptedPayload,
///        EncryptedDnsttDnsHost, EncryptedDnsttDnsPort, EncryptedDnsttServerName,
///        EncryptedDnsttPubkey},
///      SshConfig: {IsEncrypted: true, IsLocked: true, EncryptedHost,
///        EncryptedPort, EncryptedUsername, EncryptedPassword}}
///
/// Every AES field uses the SAME fixed IV and CFB-128 (the `cryptography`
/// Python default that the reference encryptor uses, and what
/// javax.crypto's "AES/CFB/NoPadding" does on Android).
///
/// The keys are not secrets — they ship inside every DarkTunnel APK; the
/// format only obfuscates. Same for this port: it exists so locked `.dark`
/// files (the standard share format of the DarkTunnel ecosystem) import
/// losslessly into Arman Tunnel, and so Sensei configs can be shared back
/// out as locked `.dark` files.

// ─────────────────────────────── SHA-256 ───────────────────────────────

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// Pure-Dart SHA-256 (needed for the DarkTunnel password-hash check — the
/// app has no crypto package and this must stay unit-testable).
Uint8List sha256Bytes(List<int> data) {
  final h = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final msgLen = data.length;
  final bitLen = msgLen * 8;
  final padded = Uint8List(((msgLen + 8) >> 6) + 1 << 6);
  padded.setRange(0, msgLen, data);
  padded[msgLen] = 0x80;
  final bd = ByteData.sublistView(padded);
  bd.setUint64(padded.length - 8, bitLen, Endian.big);

  int rotr(int x, int n) => (x >> n) | ((x << (32 - n)) & 0xffffffff);
  final w = List<int>.filled(64, 0);
  for (var block = 0; block < padded.length; block += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = bd.getUint32(block + t * 4, Endian.big);
    }
    for (var t = 16; t < 64; t++) {
      final s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final t1 = (hh + s1 + ch + _k[t] + w[t]) & 0xffffffff;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  final out = ByteData(32);
  for (var i = 0; i < 8; i++) {
    out.setUint32(i * 4, h[i], Endian.big);
  }
  return out.buffer.asUint8List();
}

String sha256Hex(String s) => sha256Bytes(utf8.encode(s))
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

// ───────────────────────── AES-128/192/256 (encrypt only) ─────────────────────────

const List<int> _sbox = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
  0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
  0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26,
  0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
  0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
  0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed,
  0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
  0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
  0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec,
  0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
  0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
  0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
  0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
  0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
  0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11,
  0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
  0xb0, 0x54, 0xbb, 0x16,
];

const List<int> _rcon = [
  0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
];

/// AES block ENCRYPTION only — CFB mode never needs the inverse cipher
/// (both CFB directions only ever run the forward cipher on the IV /
/// previous ciphertext block).
Uint8List _aesEncryptBlock(List<Uint8List> roundKeys, Uint8List block) {
  final s = Uint8List.fromList(block);
  void addRoundKey(int round) {
    final w = roundKeys[round];
    for (var i = 0; i < 16; i++) {
      s[i] ^= w[i];
    }
  }

  addRoundKey(0);
  final tmp = Uint8List(16);
  for (var round = 1; round <= roundKeys.length - 1; round++) {
    // SubBytes
    for (var i = 0; i < 16; i++) {
      s[i] = _sbox[s[i]];
    }
    // ShiftRows (flat layout: byte i = row i%4, col i~/4). Row 0 stays.
    tmp.setAll(0, s);
    for (var r = 1; r <= 3; r++) {
      for (var c = 0; c < 4; c++) {
        tmp[c * 4 + r] = s[((c + r) % 4) * 4 + r];
      }
    }
    s.setAll(0, tmp);
    if (round != roundKeys.length - 1) {
      // MixColumns
      int xtime(int x) {
        final v = x << 1;
        return (v & 0x100) != 0 ? (v ^ 0x1b) & 0xff : v;
      }

      for (var c = 0; c < 4; c++) {
        final o = c * 4;
        final a0 = s[o], a1 = s[o + 1], a2 = s[o + 2], a3 = s[o + 3];
        s[o] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;
        s[o + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;
        s[o + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);
        s[o + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);
      }
    }
    addRoundKey(round);
  }
  return s;
}

List<Uint8List> _expandKey(Uint8List key) {  final nk = key.length ~/ 4;
  final nr = nk + 6;
  final words = <Uint8List>[];
  for (var i = 0; i < nk; i++) {
    words.add(Uint8List.fromList(key.sublist(i * 4, i * 4 + 4)));
  }
  for (var i = nk; i < 4 * (nr + 1); i++) {
    final t = Uint8List.fromList(words[i - 1]);
    if (i % nk == 0) {
      // RotWord + SubWord + Rcon
      final first = t[0];
      t[0] = _sbox[t[1]] ^ _rcon[i ~/ nk - 1];
      t[1] = _sbox[t[2]];
      t[2] = _sbox[t[3]];
      t[3] = _sbox[first];
    } else if (nk > 6 && i % nk == 4) {
      for (var j = 0; j < 4; j++) {
        t[j] = _sbox[t[j]];
      }
    }
    final prev = words[i - nk];
    words.add(Uint8List.fromList([
      prev[0] ^ t[0], prev[1] ^ t[1], prev[2] ^ t[2], prev[3] ^ t[3],
    ]));
  }
  // Round keys: 4 words concatenated per round.
  final keys = <Uint8List>[];
  for (var r = 0; r <= nr; r++) {
    final rk = Uint8List(16);
    for (var c = 0; c < 4; c++) {
      rk.setRange(c * 4, c * 4 + 4, words[r * 4 + c]);
    }
    keys.add(rk);
  }
  return keys;
}

/// AES-CFB-128. [decrypt] toggles direction; both directions only use the
/// forward block cipher. Handles any data length (CFB is a stream mode).
Uint8List aesCfb128(
  Uint8List key,
  Uint8List iv,
  Uint8List data, {
  bool decrypt = false,
}) {
  final roundKeys = _expandKey(key);
  final out = Uint8List(data.length);
  var prev = iv;
  for (var off = 0; off < data.length; off += 16) {
    final keystream = _aesEncryptBlock(roundKeys, prev);
    final n = data.length - off < 16 ? data.length - off : 16;
    for (var i = 0; i < n; i++) {
      out[off + i] = data[off + i] ^ keystream[i];
    }
    // Feedback only matters when another block follows; a partial final
    // block has nothing after it.
    if (off + 16 <= data.length) {
      final fbSrc = decrypt ? data : out;
      prev = Uint8List.fromList(fbSrc.sublist(off, off + 16));
    }
  }
  return out;
}

/// Raw AES block encryption, exposed for the FIPS-197 known-answer tests
/// only — everything else goes through [aesCfb128].
Uint8List aesEncryptBlockForTest(Uint8List key, Uint8List block) =>
    _aesEncryptBlock(_expandKey(key), block);

// ─────────────────────────────── msgpack ───────────────────────────────

/// Minimal msgpack packer (subset the DarkTunnel encryptor emits: nil, bool,
/// int, float, str, bin, map, array — insertion-ordered maps).
Uint8List msgpackPack(Object? value) {
  final b = BytesBuilder();

  void pack(Object? v) {
    if (v == null) {
      b.addByte(0xc0);
    } else if (v is bool) {
      b.addByte(v ? 0xc3 : 0xc2);
    } else if (v is int) {
      if (v >= 0 && v <= 0x7f) {
        b.addByte(v);
      } else if (v >= -0x20 && v < 0) {
        b.addByte(0x100 + v);
      } else if (v >= 0 && v <= 0xff) {
        b.add([0xcc, v]);
      } else if (v >= 0 && v <= 0xffff) {
        b.add([0xcd, (v >> 8) & 0xff, v & 0xff]);
      } else if (v >= 0 && v <= 0xffffffff) {
        b.add([0xce, (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
      } else if (v > 0) {
        b.add([
          0xcf,
          for (var i = 7; i >= 0; i--) (v >> (8 * i)) & 0xff,
        ]);
      } else if (v >= -0x80) {
        b.add([0xd0, v & 0xff]);
      } else if (v >= -0x8000) {
        b.add([0xd1, (v >> 8) & 0xff, v & 0xff]);
      } else if (v >= -0x80000000) {
        b.add([0xd2, (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
      } else {
        b.add([
          0xd3,
          for (var i = 7; i >= 0; i--) (v >> (8 * i)) & 0xff,
        ]);
      }
    } else if (v is double) {
      b.addByte(0xcb);
      final bd = ByteData(8)..setFloat64(0, v, Endian.big);
      b.add(bd.buffer.asUint8List());
    } else if (v is String) {
      final e = utf8.encode(v);
      if (e.length <= 31) {
        b.addByte(0xa0 | e.length);
      } else if (e.length <= 0xff) {
        b.add([0xd9, e.length]);
      } else if (e.length <= 0xffff) {
        b.add([0xda, (e.length >> 8) & 0xff, e.length & 0xff]);
      } else {
        b.add([
          0xdb, (e.length >> 24) & 0xff, (e.length >> 16) & 0xff,
          (e.length >> 8) & 0xff, e.length & 0xff,
        ]);
      }
      b.add(e);
    } else if (v is Uint8List) {
      if (v.length <= 0xff) {
        b.add([0xc4, v.length]);
      } else if (v.length <= 0xffff) {
        b.add([0xc5, (v.length >> 8) & 0xff, v.length & 0xff]);
      } else {
        b.add([
          0xc6, (v.length >> 24) & 0xff, (v.length >> 16) & 0xff,
          (v.length >> 8) & 0xff, v.length & 0xff,
        ]);
      }
      b.add(v);
    } else if (v is Map) {
      final n = v.length;
      if (n <= 15) {
        b.addByte(0x80 | n);
      } else if (n <= 0xffff) {
        b.add([0xde, (n >> 8) & 0xff, n & 0xff]);
      } else {
        b.add([
          0xdf, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff,
        ]);
      }
      v.forEach((k, val) {
        pack(k);
        pack(val);
      });
    } else if (v is List) {
      final n = v.length;
      if (n <= 15) {
        b.addByte(0x90 | n);
      } else if (n <= 0xffff) {
        b.add([0xdc, (n >> 8) & 0xff, n & 0xff]);
      } else {
        b.add([
          0xdd, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff,
        ]);
      }
      for (final item in v) {
        pack(item);
      }
    } else {
      throw UnsupportedError('msgpack: unsupported ${v.runtimeType}');
    }
  }

  pack(value);
  return b.toBytes();
}

/// Minimal msgpack unpacker (everything the DarkTunnel format can contain).
Object? msgpackUnpack(Uint8List data) => _MsgpackReader(data).unpackAll();

class _MsgpackReader {
  final Uint8List data;
  var pos = 0;
  _MsgpackReader(this.data);

  int u8() => data[pos++];

  Uint8List take(int n) {
    if (pos + n > data.length) {
      throw const FormatException('msgpack: truncated');
    }
    final r = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return r;
  }

  Object? unpack() {
    final code = u8();
    if (code <= 0x7f) return code;
    if (code >= 0xe0) return code - 0x100;
    if (code >= 0x80 && code <= 0x8f) {
      return _readMap(code & 0x0f);
    }
    if (code >= 0x90 && code <= 0x9f) {
      return _readArray(code & 0x0f);
    }
    if (code >= 0xa0 && code <= 0xbf) {
      return utf8.decode(take(code & 0x1f));
    }
    switch (code) {
      case 0xc0: return null;
      case 0xc2: return false;
      case 0xc3: return true;
      case 0xc4: return take(u8());
      case 0xc5: return take((u8() << 8) | u8());
      case 0xc6: return take((u8() << 24) | (u8() << 16) | (u8() << 8) | u8());
      case 0xca:
        return ByteData.sublistView(take(4)).getFloat32(0, Endian.big);
      case 0xcb:
        return ByteData.sublistView(take(8)).getFloat64(0, Endian.big);
      case 0xcc: return u8();
      case 0xcd: return (u8() << 8) | u8();
      case 0xce: return (u8() << 24) | (u8() << 16) | (u8() << 8) | u8();
      case 0xcf:
        var v = 0;
        for (var i = 0; i < 8; i++) {
          v = (v << 8) | u8();
        }
        return v;
      case 0xd0: return u8().toSigned(8);
      case 0xd1: return ((u8() << 8) | u8()).toSigned(16);
      case 0xd2:
        return (((u8() << 24) | (u8() << 16)) | (u8() << 8) | u8())
            .toSigned(32);
      case 0xd3:
        var v = 0;
        for (var i = 0; i < 8; i++) {
          v = (v << 8) | u8();
        }
        return v;
      case 0xd9: return utf8.decode(take(u8()));
      case 0xda: return utf8.decode(take((u8() << 8) | u8()));
      case 0xdb: return utf8.decode(take((u8() << 24) | (u8() << 16) | (u8() << 8) | u8()));
      case 0xdc: return _readArray((u8() << 8) | u8());
      case 0xdd: return _readArray((u8() << 24) | (u8() << 16) | (u8() << 8) | u8());
      case 0xde: return _readMap((u8() << 8) | u8());
      case 0xdf: return _readMap((u8() << 24) | (u8() << 16) | (u8() << 8) | u8());
      default:
        throw FormatException('msgpack: unsupported marker 0x${code.toRadixString(16)}');
    }
  }

  Map<Object?, Object?> _readMap(int n) {
    final m = <Object?, Object?>{};
    for (var i = 0; i < n; i++) {
      final k = unpack();
      final v = unpack();
      m[k] = v;
    }
    return m;
  }

  List<Object?> _readArray(int n) {
    final l = <Object?>[];
    for (var i = 0; i < n; i++) {
      l.add(unpack());
    }
    return l;
  }

  Object? unpackAll() {
    final result = unpack();
    if (pos != data.length) {
      throw FormatException('msgpack: ${data.length - pos} trailing bytes');
    }
    return result;
  }
}

// ─────────────────────────── DarkTunnel codec ───────────────────────────

class DarkTunnelCodec {
  DarkTunnelCodec._();

  static final Uint8List outerKey =
      Uint8List.fromList(utf8.encode(r'$B&E)H@McQfThWmZq4t7w!z%C*F-JaNd'));
  static final Uint8List innerKey =
      Uint8List.fromList(utf8.encode('F)J@NcRfUjXn2r4u7x!A%D*G'));
  static final Uint8List iv = Uint8List.fromList([
    0x23, 0x2e, 0x39, 0x18, 0x55, 0x23, 0x18, 0x4a,
    0x57, 0x23, 0x58, 0x62, 0x42, 0x20, 0x0e, 0x05,
  ]);

  /// Version metadata the reference encryptor writes; the Android app only
  /// reads it for display, so the exact values are cosmetic.
  static const _versionCode = 32;
  static const _versionName = '1.0.26';

  /// sha256('') — the marker of a config with NO lock password (the
  /// reference encryptor's convention).
  static const emptySha256Hex =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  /// The real DarkTunnel app's own no-password marker: a survey of 286
  /// locked .dark files (2025-2026, many sellers) shows EVERY passwordless
  /// config carries this exact hash — it is what the app writes when the
  /// seller leaves the lock password empty. Anything other than this or
  /// [emptySha256Hex] is a real password lock.
  static const appDefaultNoPasswordHash =
      'b766445beb8f36e546364de9bb05db5c5d94a80941ac50e323ed3cf0469e2a73';

  /// Characters that can legitimately appear in a `darktunnel://` payload:
  /// the base64url + standard-base64 alphabets, padding, and `%` (for the
  /// URL-escaped `%2B`/`%2F`/`%3D` variants shares sometimes travel as).
  static final RegExp _b64Run = RegExp(r'^[A-Za-z0-9_\-+/=%]+');

  /// Cut everything after the base64 payload. Telegram/DarkTunnel bulk shares
  /// glue `,`, newlines or emoji onto the link ("all type not support" was
  /// this: `base64Url.decode` threw on the trailing `,`). A `=` seen in the
  /// middle ends the payload — padding is never followed by alphabet chars.
  static String b64Trim(String value) {
    final v = value.trim();
    if (v.isEmpty) return v;
    final run = _b64Run.firstMatch(v)?.group(0) ?? '';
    final eq = run.indexOf('=');
    if (eq != -1) {
      var k = eq;
      while (k < run.length && run[k] == '=') {
        k++;
      }
      if (k < run.length) return run.substring(0, eq);
    }
    return run;
  }

  /// Every complete `darktunnel://` URI inside [text] — bulk pastes are
  /// comma/newline/quote separated, and the payload alphabet never contains
  /// those characters, so a regex split is safe here.
  static final RegExp _uriRe =
      RegExp(r'darktunnel://[A-Za-z0-9_\-+/=%]+={0,2}', caseSensitive: false);

  static List<String> extractUris(String text) =>
      _uriRe.allMatches(text).map((m) => m.group(0)!).toList();

  static Uint8List _b64decodeAny(String value) {
    var v = b64Trim(value);
    // Shares sometimes travel URL-escaped.
    v = v.replaceAll('%2B', '+').replaceAll('%2F', '/').replaceAll('%3D', '=');
    v += '=' * ((4 - v.length % 4) % 4);
    final normalized = v.replaceAll('-', '+').replaceAll('_', '/');
    return base64.decode(normalized);
  }

  /// Decrypt a `darktunnel://` URI's locked envelope. Returns null for
  /// unlocked configs and for anything that fails to decrypt.
  static DarkTunnelLock? decode(String uri) {
    try {
      final t = uri.trim();
      if (!t.startsWith('darktunnel://')) return null;
      final Map<String, dynamic> top =
          jsonDecode(utf8.decode(_b64decodeAny(t.substring('darktunnel://'.length))));
      final enc = top['encryptedLockedConfig'];
      if (enc is! String || enc.isEmpty) return null;

      final outer =
          msgpackUnpack(aesCfb128(outerKey, iv, _b64decodeAny(enc), decrypt: true))
              as Map;
      final lockedApp = outer['LockedAppConfig'] as Map?;
      final innerBlob = outer['EncryptedLockedConfig'];
      if (lockedApp == null || innerBlob is! Uint8List || innerBlob.isEmpty) {
        return null;
      }
      final innerRaw =
          msgpackUnpack(aesCfb128(innerKey, iv, innerBlob, decrypt: true)) as Map;
      final inner = _decryptInner(innerRaw) as Map<String, dynamic>;

      // The 96-byte Password blob: 64 ASCII hex chars of sha256(password)
      // + 32 raw bytes of sha256('') (a constant tail the format adds).
      String pwHex = '';
      final pw = lockedApp['Password'];
      if (pw is Uint8List && pw.length == 96) {
        pwHex = latin1.decode(pw.sublist(0, 64));
      }

      int exp = 0;
      final rawExp = lockedApp['ExpiredAtTimestamp'];
      if (rawExp is int) exp = rawExp;
      // DarkTunnel writes Unix SECONDS; the app stores epoch ms.
      if (exp > 0 && exp < 1000000000000) exp *= 1000;

      return DarkTunnelLock(
        tunnelType: (lockedApp['TunnelType'] ?? top['type'] ?? '')
            .toString()
            .toUpperCase(),
        // The real app packs these as msgpack BIN, not str.
        message: _binToText(lockedApp['Message']),
        connectedMessage: _binToText(lockedApp['ConnectedMessage']),
        expiresAtMs: exp,
        passwordHashHex: pwHex,
        isSshLocked: lockedApp['IsSshLocked'] == true,
        inner: inner,
      );
    } catch (_) {
      return null;
    }
  }

  static String _binToText(Object? v) {
    if (v is Uint8List) {
      try {
        return utf8.decode(v);
      } catch (_) {
        return '';
      }
    }
    return v?.toString() ?? '';
  }

  /// Walk the inner msgpack tree and decrypt every `Encrypted*` field
  /// (dropping the prefix), mirroring the reference decryptor.
  static dynamic _decryptInner(Object? value) {
    if (value is Map) {
      final out = <String, dynamic>{};
      value.forEach((k, v) {
        final key = k is String ? k : k.toString();
        if (key.startsWith('Encrypted') && v is Uint8List) {
          try {
            final plain = aesCfb128(innerKey, iv, v, decrypt: true);
            out[key.substring('Encrypted'.length)] = utf8.decode(plain);
          } catch (_) {
            out[key.substring('Encrypted'.length)] = v;
          }
        } else {
          out[key] = _decryptInner(v);
        }
      });
      return out;
    }
    if (value is List) return value.map(_decryptInner).toList();
    return value;
  }

  /// Fast pre-check for the import UI: does this .dark need a password?
  static bool requiresPassword(String uri) =>
      decode(uri)?.passwordRequired ?? false;

  /// The reference encryptor's 96-byte Password blob.
  static Uint8List _passwordBlob(String password) {
    final out = BytesBuilder();
    out.add(latin1.encode(sha256Hex(password))); // 64 ASCII hex chars
    out.add(sha256Bytes(const [])); // 32 raw bytes of sha256('')
    return out.toBytes();
  }

  /// The stock payload string the real app writes into the unused
  /// InjectConfig of v2ray-type locked configs.
  static const _defaultSshPayload =
      '[method] [host_port] [protocol][crlf]Host: [host][crlf]Service: '
      'SSH[crlf]Mode: Bypass[crlf][crlf]';

  static Map<String, Object?> _buildInjectSection(
    Uint8List Function(String) field,
    String injectMode,
    String proxyHost,
    String proxyPort,
    String sni,
    String payload,
    String dnsttDnsHost,
    String dnsttDnsPort,
    String dnsttServerName,
    String dnsttPubkey,
  ) =>
      <String, Object?>{
        'IsEncrypted': true,
        'EncryptedMode': field(injectMode.isEmpty ? 'DIRECT' : injectMode),
        'EncryptedProxyHost':
            field(proxyHost.isEmpty ? 'localhost' : proxyHost),
        'EncryptedProxyPort': field(proxyPort.isEmpty ? '8080' : proxyPort),
        'EncryptedServerNameIndication': field(sni),
        'EncryptedPayload': field(payload),
        'EncryptedDnsttDnsHost': field(dnsttDnsHost.isEmpty ? '1.1.1.1' : dnsttDnsHost),
        'EncryptedDnsttDnsPort': field(dnsttDnsPort.isEmpty ? '53' : dnsttDnsPort),
        'EncryptedDnsttServerName': field(dnsttServerName),
        'EncryptedDnsttPubkey': field(dnsttPubkey),
      };

  /// Build a locked `darktunnel://…` share. Returns null when the payload
  /// doesn't fit the format (no v2ray config AND no ssh host).
  static String? encodeLocked({
    required String tunnelType,
    required String name,
    String countryIso = '',
    String sshHost = '',
    String sshPort = '',
    String sshUsername = '',
    String sshPassword = '',
    String injectMode = 'DIRECT',
    String proxyHost = '',
    String proxyPort = '',
    String sni = '',
    String payload = '',
    String dnsttDnsHost = '1.1.1.1',
    String dnsttDnsPort = '53',
    String dnsttServerName = '',
    String dnsttPubkey = '',
    String? v2rayConfigJson,
    bool v2rayInjectMode = false,
    String password = '',
    int expiresAtSec = 0,
    String message = '',
    String connectedMessage = '',
  }) {
    try {
      final type = tunnelType.toUpperCase();
      final isSsh = type == 'SSH' || type == 'SSH_DNSTT';
      if (!isSsh && (v2rayConfigJson == null || v2rayConfigJson.isEmpty)) {
        return null;
      }
      if (isSsh && sshHost.isEmpty) return null;

      Uint8List field(String v) =>
          aesCfb128(innerKey, iv, Uint8List.fromList(utf8.encode(v)));

      final inner = <String, Object?>{};
      if (isSsh) {
        inner['InjectConfig'] = _buildInjectSection(
          field, injectMode, proxyHost, proxyPort, sni, payload,
          dnsttDnsHost, dnsttDnsPort, dnsttServerName, dnsttPubkey,
        );
        inner['SshConfig'] = {
          'IsEncrypted': true,
          'IsLocked': true,
          'EncryptedHost': field(sshHost),
          'EncryptedPort': field(sshPort.isEmpty ? '80' : sshPort),
          'EncryptedUsername': field(sshUsername),
          'EncryptedPassword': field(sshPassword),
        };
      } else {
        // The real app expects ALL three sections — v2ray configs carry an
        // empty/default SshConfig + InjectConfig alongside the real
        // V2RayConfig (verified against every real locked file; the default
        // SSH payload string is what the app itself writes there).
        inner['InjectConfig'] = _buildInjectSection(
          field, 'DIRECT', '', '', '', _defaultSshPayload, '', '', '', '',
        );
        inner['SshConfig'] = {
          'IsEncrypted': true,
          'IsLocked': true,
          'EncryptedHost': field(''),
          'EncryptedPort': field('80'),
          'EncryptedUsername': field(''),
          'EncryptedPassword': field(''),
        };
        inner['V2RayConfig'] = {
          'IsEncrypted': true,
          'IsInjectModeEnabled': v2rayInjectMode,
          'EncryptedConfig': field(v2rayConfigJson!),
        };
      }
      final innerBlob =
          aesCfb128(innerKey, iv, msgpackPack(inner));

      final outer = <String, Object?>{
        'LockedAppConfig': {
          'VersionCode': _versionCode,
          'VersionName': _versionName,
          'Message': message.isEmpty ? 'Config Created' : message,
          'ConnectedMessage': connectedMessage.isEmpty ? 'Connected' : connectedMessage,
          'Password': _passwordBlob(password),
          'ExpiredAtTimestamp': expiresAtSec,
          'HardwareIdList': <String>[],
          'TunnelType': type,
          'IsSshLocked': isSsh,
        },
        'EncryptedLockedConfig': innerBlob,
      };
      final outerBlob = aesCfb128(outerKey, iv, msgpackPack(outer));

      // Visible decoy tunnel config — exactly what the reference writes.
      final parts = type.toLowerCase().split('_');
      final tunnelKey =
          '${parts[0]}${parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join()}TunnelConfig';
      final visible = <String, Object?>{};
      if (type == 'VLESS' || type == 'VMESS' || type == 'TROJAN') {
        visible['v2rayConfig'] = {
          'tls': v2rayConfigJson?.contains('"security":"tls"') ?? false,
        };
      } else if (isSsh) {
        visible['injectConfig'] = {'enabled': true, 'mode': injectMode};
      }

      final config = <String, Object?>{
        'type': type,
        'name': name,
        if (countryIso.isNotEmpty) 'countryIso': countryIso,
        tunnelKey: visible,
        'encryptedLockedConfig':
            base64.encode(outerBlob).replaceAll('+', '-').replaceAll('/', '_'),
      };
      final json = jsonEncode(config);
      final b64 = base64
          .encode(utf8.encode(json))
          .replaceAll('+', '-')
          .replaceAll('/', '_')
          .replaceAll('=', '');
      return 'darktunnel://$b64';
    } catch (_) {
      return null;
    }
  }

  /// Build the DarkTunnel V2Ray config-JSON template (with its `$TOKEN`
  /// placeholders) — byte-compatible with the reference encryptor's
  /// `build_v2ray_config`.
  static String buildV2RayTemplateJson({
    required String protocol, // vless | vmess
    required String address,
    required int port,
    required String uuidStr,
    required String network, // ws | tcp | grpc
    required String security, // none | tls
    String wsPath = '',
    String wsHost = '',
    String tlsSni = '',
    String grpcService = '',
    String flow = '',
  }) {
    final user = <String, Object?>{
      'id': uuidStr,
      'flow': flow,
      'level': 8,
      'security': 'chacha20-poly1305',
      if (protocol == 'vless') 'encryption': 'none',
      if (protocol == 'vmess') ...{'alterId': 0, 'encryption': ''},
    };
    final stream = <String, Object?>{
      'network': network,
      'security': security,
      'tlsSettings': {
        'allowInsecure': true,
        'serverName': security == 'tls' ? tlsSni : '',
      },
      if (network == 'ws')
        'wsSettings': {
          'headers': {if (wsHost.isNotEmpty) 'Host': wsHost},
          'path': wsPath,
        },
      if (network == 'grpc') 'grpcSettings': {'serviceName': grpcService},
    };
    final config = <String, Object?>{
      'inbounds': [
        {
          'listen': r'$SOCKS5_LISTEN_HOST',
          'port': r'$SOCKS5_LISTEN_PORT',
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true, 'userLevel': 8},
        },
        {
          'listen': r'$HTTP_LISTEN_HOST',
          'port': r'$HTTP_LISTEN_PORT',
          'protocol': 'http',
          'settings': {'userLevel': 8},
        },
      ],
      'log': {'loglevel': 'none'},
      'outbounds': [
        {
          'mux': {'concurrency': 8, 'enabled': r'$MUX_ENABLED'},
          'protocol': protocol,
          'settings': {
            'vnext': [
              {
                'address': address,
                'port': port,
                'users': [user],
              }
            ]
          },
          'streamSettings': stream,
        }
      ],
      'policy': {
        'levels': {
          '8': {
            'connIdle': 300,
            'downlinkOnly': 1,
            'handshake': 4,
            'uplinkOnly': 1,
          }
        },
        'system': {
          'statsOutboundUplink': false,
          'statsOutboundDownlink': false,
        },
      },
      'stats': <String, Object?>{},
    };
    final json = jsonEncode(config);
    // Un-quote the placeholder tokens, exactly like the reference.
    return json
        .replaceAll('"${r'$'}SOCKS5_LISTEN_HOST"', r'$SOCKS5_LISTEN_HOST')
        .replaceAll('"${r'$'}SOCKS5_LISTEN_PORT"', r'$SOCKS5_LISTEN_PORT')
        .replaceAll('"${r'$'}HTTP_LISTEN_HOST"', r'$HTTP_LISTEN_HOST')
        .replaceAll('"${r'$'}HTTP_LISTEN_PORT"', r'$HTTP_LISTEN_PORT')
        .replaceAll('"${r'$'}MUX_ENABLED"', r'$MUX_ENABLED');
  }

  /// Replace the `$TOKEN` placeholders in a decrypted V2RayConfig with
  /// syntactically valid values so the JSON parses (we only read
  /// outbounds[0]; the tokens live in inbounds/mux).
  static String sanitizeV2RayTemplate(String s) => s
      .replaceAll(RegExp(r':\s*\$SOCKS5_LISTEN_HOST'), ': "127.0.0.1"')
      .replaceAll(RegExp(r':\s*\$SOCKS5_LISTEN_PORT'), ': 10808')
      .replaceAll(RegExp(r':\s*\$HTTP_LISTEN_HOST'), ': "127.0.0.1"')
      .replaceAll(RegExp(r':\s*\$HTTP_LISTEN_PORT'), ': 10809')
      .replaceAll(RegExp(r':\s*\$MUX_ENABLED'), ': true')
      // Unknown tokens — same fallback as the reference decryptor.
      .replaceAll(RegExp(r':\s*\$[A-Z0-9_]+'), ': true');
}

/// A decrypted DarkTunnel lock envelope.
class DarkTunnelLock {
  /// SSH | SSH_DNSTT | VLESS | VMESS | TROJAN | V2RAY_CUSTOM_CONFIG
  final String tunnelType;
  final String message;
  final String connectedMessage;

  /// Epoch milliseconds (DarkTunnel stores seconds; normalized here).
  final int expiresAtMs;

  /// First 64 bytes of the 96-byte Password blob — hex of sha256(pw).
  final String passwordHashHex;
  final bool isSshLocked;

  /// Decrypted inner sections: V2RayConfig{Config, IsInjectModeEnabled} or
  /// InjectConfig{Mode, Payload, …} + SshConfig{Host, Port, Username,
  /// Password}.
  final Map<String, dynamic> inner;

  const DarkTunnelLock({
    required this.tunnelType,
    required this.message,
    required this.connectedMessage,
    required this.expiresAtMs,
    required this.passwordHashHex,
    required this.isSshLocked,
    required this.inner,
  });

  bool get passwordRequired =>
      passwordHashHex.isNotEmpty &&
      passwordHashHex != DarkTunnelCodec.emptySha256Hex &&
      passwordHashHex != DarkTunnelCodec.appDefaultNoPasswordHash;

  bool checkPin(String pin) => sha256Hex(pin) == passwordHashHex;

  Map<String, dynamic> get v2rayConfig =>
      (inner['V2RayConfig'] as Map?)?.cast<String, dynamic>() ?? const {};

  String? get v2rayConfigJson => v2rayConfig['Config'] as String?;

  Map<String, dynamic> get sshConfig =>
      (inner['SshConfig'] as Map?)?.cast<String, dynamic>() ?? const {};

  Map<String, dynamic> get injectConfig =>
      (inner['InjectConfig'] as Map?)?.cast<String, dynamic>() ?? const {};
}
