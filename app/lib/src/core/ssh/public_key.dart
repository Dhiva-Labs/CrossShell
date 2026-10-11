// Strict OpenSSH public key parsing.
//
// Keys from a peer end up in authorized_keys and known_hosts, so they are
// validated to exactly `<type> <base64>`: no options (`command=…`), no
// embedded newlines, and the type inside the blob must match the prefix.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const allowedKeyTypes = {
  'ssh-ed25519',
  'ecdsa-sha2-nistp256',
  'ecdsa-sha2-nistp384',
  'ecdsa-sha2-nistp521',
  'ssh-rsa',
};

class PublicKey {
  PublicKey._(this.type, this.base64Blob, this.blob);

  final String type;
  final String base64Blob;
  final Uint8List blob;

  /// `<type> <base64>` with no comment.
  String get line => '$type $base64Blob';

  /// Parse `<type> <base64> [comment]`. Throws [FormatException].
  factory PublicKey.parse(String input) {
    final s = input.trim();
    if (s.contains('\n') || s.contains('\r') || s.contains('\x00')) {
      throw const FormatException('public key must be a single line');
    }
    final parts = s.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      throw const FormatException('not an OpenSSH public key');
    }
    final type = parts[0];
    final b64 = parts[1];
    if (!allowedKeyTypes.contains(type)) {
      throw FormatException('unsupported key type "$type"');
    }
    if (!RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(b64) || b64.length > 2048) {
      throw const FormatException('malformed key data');
    }
    final Uint8List blob;
    try {
      blob = base64.decode(b64);
    } on FormatException {
      throw const FormatException('malformed key data');
    }
    // The blob starts with the length-prefixed key type.
    if (blob.length < 4) throw const FormatException('key data too short');
    final n = (blob[0] << 24) | (blob[1] << 16) | (blob[2] << 8) | blob[3];
    if (n <= 0 || 4 + n > blob.length) {
      throw const FormatException('key data truncated');
    }
    final inner = ascii.decode(blob.sublist(4, 4 + n), allowInvalid: true);
    if (inner != type) {
      throw FormatException(
        'key type "$type" does not match its data ("$inner")',
      );
    }
    return PublicKey._(type, b64, blob);
  }

  /// OpenSSH-style `SHA256:<base64 without padding>` — the format dartssh2
  /// hands to `onVerifyHostKey`.
  Future<String> sha256Fingerprint() async {
    final h = await Sha256().hash(blob);
    return 'SHA256:${base64.encode(h.bytes).replaceAll('=', '')}';
  }

  @override
  bool operator ==(Object other) => other is PublicKey && other.line == line;

  @override
  int get hashCode => line.hashCode;

  @override
  String toString() => line;
}

/// True if [s] parses as a public key.
bool isValidPublicKey(String s) {
  try {
    PublicKey.parse(s);
    return true;
  } on FormatException {
    return false;
  }
}
