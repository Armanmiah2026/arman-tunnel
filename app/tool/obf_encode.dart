// ignore_for_file: avoid_print
// XOR-encodes a string for lib/services/obf.dart.
//
//   dart run tool/obf_encode.dart "https://cdn.yourdomain.com/configs/app.enc"
//
// Prints the base64 payload to paste into the matching Obf getter.
// The key MUST stay identical to the `_key` constant in obf.dart.
import 'dart:convert';
import 'dart:io';

const String key = 'SnSeiTnL::2026::cfgK';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/obf_encode.dart "<string>"');
    exit(2);
  }
  final bytes = utf8.encode(args.join(' '));
  final keyBytes = utf8.encode(key);
  final out = List<int>.filled(bytes.length, 0);
  for (var i = 0; i < bytes.length; i++) {
    out[i] = bytes[i] ^ keyBytes[i % keyBytes.length];
  }
  print(base64Encode(out));
}
