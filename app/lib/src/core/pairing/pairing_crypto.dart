// Pairing crypto: numeric comparison with a commitment (PLAN.md "Pairing").
//
// Initiator I commits to its ephemeral X25519 key before seeing R's key, and
// R reveals its key before seeing I's, so a man in the middle cannot grind
// keys until both screens show the same 6 digits: it gets one 1-in-10^6
// guess per attempt. Once both users confirm, each side seals its payload
// with a direction-specific key derived from the shared secret.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _commitLabel = 'cs-commit';
const _transcriptLabel = 'cs-pair-v1';
const _sasLabel = 'cs-sas';
const keyInfoInitiator = 'cs-pair-key-I';
const keyInfoResponder = 'cs-pair-key-R';

final _x25519 = X25519();
final _sha256 = Sha256();
final _aead = Chacha20.poly1305Aead();

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// A fresh ephemeral key pair plus its 32-byte public key.
class Ephemeral {
  Ephemeral._(this.keyPair, this.publicKey);
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  static Future<Ephemeral> generate() async {
    final kp = await _x25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    return Ephemeral._(kp, Uint8List.fromList(pub.bytes));
  }

  Future<Uint8List> sharedSecret(Uint8List peerPublic) async {
    if (peerPublic.length != 32) {
      throw const FormatException('peer public key must be 32 bytes');
    }
    final s = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(peerPublic, type: KeyPairType.x25519),
    );
    final bytes = Uint8List.fromList(await s.extractBytes());
    // An all-zero result means a low-order peer key: refuse it.
    if (bytes.every((b) => b == 0)) {
      throw const FormatException('degenerate shared secret');
    }
    return bytes;
  }
}

Uint8List _lp(List<int> b) {
  // u16 big-endian length prefix, so concatenated fields can't be confused.
  if (b.length > 0xffff) throw ArgumentError('field too long');
  return Uint8List.fromList([b.length >> 8, b.length & 0xff, ...b]);
}

Future<Uint8List> _hash(List<List<int>> parts) async {
  final h = await _sha256.hash([for (final p in parts) ...p]);
  return Uint8List.fromList(h.bytes);
}

/// `H("cs-commit" ‖ pkI ‖ nI)`
Future<Uint8List> commitment(Uint8List pkI, Uint8List nonceI) =>
    _hash([utf8.encode(_commitLabel), pkI, nonceI]);

/// `H("cs-pair-v1" ‖ pkI ‖ pkR ‖ nI ‖ lp(idI) ‖ lp(idR))`
Future<Uint8List> transcriptHash({
  required Uint8List pkI,
  required Uint8List pkR,
  required Uint8List nonceI,
  required String idI,
  required String idR,
}) =>
    _hash([
      utf8.encode(_transcriptLabel),
      pkI,
      pkR,
      nonceI,
      _lp(utf8.encode(idI)),
      _lp(utf8.encode(idR)),
    ]);

/// Six-digit short authentication string from the transcript hash.
Future<int> sasCode(Uint8List transcript) async {
  final h = await _hash([utf8.encode(_sasLabel), transcript]);
  final v = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
  return (v & 0xffffffff) % 1000000;
}

/// `123456` → `"123 456"`.
String formatSas(int code) {
  final s = code.toString().padLeft(6, '0');
  return '${s.substring(0, 3)} ${s.substring(3)}';
}

/// HKDF-SHA256(ss, salt = transcript, info) → 32-byte key.
Future<SecretKey> deriveKey(
  Uint8List sharedSecret,
  Uint8List transcript,
  String info,
) {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  return hkdf.deriveKey(
    secretKey: SecretKey(sharedSecret),
    nonce: transcript,
    info: utf8.encode(info),
  );
}

/// `nonce12 ‖ ciphertext ‖ tag16`
Future<Uint8List> seal(SecretKey key, List<int> plaintext) async {
  final nonce = randomBytes(12);
  final box = await _aead.encrypt(plaintext, secretKey: key, nonce: nonce);
  return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
}

/// Inverse of [seal]; throws on any tampering.
Future<Uint8List> open(SecretKey key, Uint8List sealed) async {
  if (sealed.length < 12 + 16) {
    throw const FormatException('sealed payload too short');
  }
  final box = SecretBox(
    sealed.sublist(12, sealed.length - 16),
    nonce: sealed.sublist(0, 12),
    mac: Mac(sealed.sublist(sealed.length - 16)),
  );
  return Uint8List.fromList(await _aead.decrypt(box, secretKey: key));
}

/// Constant-time byte comparison.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
