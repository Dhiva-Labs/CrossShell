// The pairing ceremony itself (PLAN.md "Pairing"), for both roles.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pairing_crypto.dart';
import 'pairing_messages.dart';

const _stepTimeout = Duration(seconds: 10);
const confirmTimeout = Duration(seconds: 120);
// The other side may be sitting in a UAC / polkit prompt while it applies.
const _applyTimeout = Duration(seconds: 180);

/// Shown to the user on both machines.
class PairingPrompt {
  PairingPrompt({
    required this.peer,
    required this.code,
    required this.incoming,
    required this.remoteCancelled,
  });

  final PeerIdentity peer;

  /// `"123 456"` — must match the other screen.
  final String code;

  /// True on the machine that received the request.
  final bool incoming;

  /// Completes with a reason if the other side cancels while the prompt is
  /// up; the UI should close its dialog.
  final Future<String> remoteCancelled;
}

/// Resolve true when the user says the codes match, false to reject.
typedef ConfirmCode = Future<bool> Function(PairingPrompt prompt);

/// Persist trust in the peer (authorized_keys, known_hosts, ssh config,
/// peer list). Throwing aborts the pairing and the message is shown to both
/// users.
typedef ApplyPeer =
    Future<void> Function(
      PeerIdentity peer,
      PairingPayload payload,
      String peerAddress,
    );

class PairingOutcome {
  PairingOutcome(this.peer, this.payload, this.peerAddress);
  final PeerIdentity peer;
  final PairingPayload payload;
  final String peerAddress;
}

Uint8List _b64(Object? v, int len, String what) {
  if (v is! String) throw PairingError('missing $what');
  final Uint8List b;
  try {
    b = base64.decode(v);
  } on FormatException {
    throw PairingError('malformed $what');
  }
  if (b.length != len) throw PairingError('$what has the wrong length');
  return b;
}

/// Start pairing with the machine at [host]:[port].
Future<PairingOutcome> initiatePairing({
  required String host,
  required int port,
  required PeerIdentity me,
  required PairingPayload myPayload,
  required ConfirmCode confirm,
  required ApplyPeer apply,
}) async {
  final Socket socket;
  try {
    socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
  } on SocketException catch (e) {
    throw PairingError(
      'cannot reach $host:$port — is CrossShell open there? (${e.osError?.message ?? e.message})',
    );
  }
  final ch = FrameChannel(socket);
  try {
    final eph = await Ephemeral.generate();
    final nonce = randomBytes(32);
    ch.send({
      't': 'hello',
      'v': pairingProtocolVersion,
      ...me.toJson(),
      'commit': base64.encode(await commitment(eph.publicKey, nonce)),
    });
    final key = await ch.expect('key', confirmTimeout);
    final peer = PeerIdentity.fromJson(key);
    if (peer.id == me.id) throw PairingError('that is this machine');
    final pkR = _b64(key['pk'], 32, 'peer key');
    ch.send({
      't': 'reveal',
      'pk': base64.encode(eph.publicKey),
      'nonce': base64.encode(nonce),
    });

    final ss = await eph.sharedSecret(pkR);
    final th = await transcriptHash(
      pkI: eph.publicKey,
      pkR: pkR,
      nonceI: nonce,
      idI: me.id,
      idR: peer.id,
    );
    return await _confirmAndExchange(
      ch: ch,
      peer: peer,
      sharedSecret: ss,
      transcript: th,
      initiator: true,
      myPayload: myPayload,
      confirm: confirm,
      apply: apply,
      peerAddress: socket.remoteAddress.address,
    );
  } catch (e) {
    if (e is! PairingError) ch.send({'t': 'abort', 'reason': 'internal error'});
    rethrow;
  } finally {
    await ch.close();
  }
}

/// Handle one incoming pairing connection.
Future<PairingOutcome> respondToPairing({
  required Socket socket,
  required PeerIdentity me,
  required PairingPayload myPayload,
  required ConfirmCode confirm,
  required ApplyPeer apply,
}) async {
  final ch = FrameChannel(socket);
  try {
    final hello = await ch.expect('hello', _stepTimeout);
    if (hello['v'] != pairingProtocolVersion) {
      ch.send({
        't': 'abort',
        'reason': 'unsupported pairing version ${hello['v']}',
      });
      throw PairingError(
        'the other device runs an incompatible CrossShell version',
      );
    }
    final peer = PeerIdentity.fromJson(hello);
    if (peer.id == me.id) throw PairingError('refusing to pair with myself');
    final commit = _b64(hello['commit'], 32, 'commitment');

    final eph = await Ephemeral.generate();
    ch.send({'t': 'key', ...me.toJson(), 'pk': base64.encode(eph.publicKey)});
    final reveal = await ch.expect('reveal', _stepTimeout);
    final pkI = _b64(reveal['pk'], 32, 'peer key');
    final nonce = _b64(reveal['nonce'], 32, 'nonce');
    if (!constantTimeEquals(await commitment(pkI, nonce), commit)) {
      ch.send({'t': 'abort', 'reason': 'commitment mismatch'});
      throw PairingError(
        'the other device broke the pairing protocol (commitment mismatch) — possible interception',
      );
    }

    final ss = await eph.sharedSecret(pkI);
    final th = await transcriptHash(
      pkI: pkI,
      pkR: eph.publicKey,
      nonceI: nonce,
      idI: peer.id,
      idR: me.id,
    );
    return await _confirmAndExchange(
      ch: ch,
      peer: peer,
      sharedSecret: ss,
      transcript: th,
      initiator: false,
      myPayload: myPayload,
      confirm: confirm,
      apply: apply,
      peerAddress: socket.remoteAddress.address,
    );
  } catch (e) {
    if (e is! PairingError) ch.send({'t': 'abort', 'reason': 'internal error'});
    rethrow;
  } finally {
    await ch.close();
  }
}

/// Tell a connection we're already busy with another pairing.
void rejectBusy(Socket socket) {
  final ch = FrameChannel(socket);
  ch.send({'t': 'busy'});
  ch.close();
}

Future<PairingOutcome> _confirmAndExchange({
  required FrameChannel ch,
  required PeerIdentity peer,
  required Uint8List sharedSecret,
  required Uint8List transcript,
  required bool initiator,
  required PairingPayload myPayload,
  required ConfirmCode confirm,
  required ApplyPeer apply,
  required String peerAddress,
}) async {
  final code = formatSas(await sasCode(transcript));

  // Read the other side's verdict while our user looks at the code.
  final cancelled = Completer<String>();
  final remoteVerdict = ch
      .next(confirmTimeout + _stepTimeout)
      .then(
        (m) {
          if (m['t'] != 'confirm' && !cancelled.isCompleted) {
            cancelled.complete(
              m['t'] == 'abort' ? sanitizeName(m['reason']) : 'protocol error',
            );
          }
          return m;
        },
        onError: (Object e) {
          if (!cancelled.isCompleted) cancelled.complete(e.toString());
          throw e;
        },
      );
  // Errors surface where we await it below; don't report them as uncaught
  // while the user is still looking at the code.
  remoteVerdict.ignore();

  final ok = await confirm(
    PairingPrompt(
      peer: peer,
      code: code,
      incoming: !initiator,
      remoteCancelled: cancelled.future,
    ),
  ).timeout(confirmTimeout, onTimeout: () => false);
  if (!ok) {
    final remoteReason = cancelled.isCompleted ? await cancelled.future : null;
    // Close the local dialog too if we got here by timing out.
    if (!cancelled.isCompleted) cancelled.complete('timed out');
    ch.send({'t': 'abort', 'reason': 'code rejected or timed out'});
    if (remoteReason != null) {
      throw PairingError('the other device cancelled: $remoteReason');
    }
    throw PairingError('pairing cancelled');
  }
  ch.send({'t': 'confirm'});
  final verdict = await remoteVerdict;
  if (verdict['t'] != 'confirm') {
    throw PairingError('the other device declined: ${await cancelled.future}');
  }

  // Both users confirmed the same code: exchange sealed payloads.
  final myKey = await deriveKey(
    sharedSecret,
    transcript,
    initiator ? keyInfoInitiator : keyInfoResponder,
  );
  final theirKey = await deriveKey(
    sharedSecret,
    transcript,
    initiator ? keyInfoResponder : keyInfoInitiator,
  );
  ch.send({
    't': 'payload',
    'box': base64.encode(
      await seal(myKey, utf8.encode(jsonEncode(myPayload.toJson()))),
    ),
  });
  final boxMsg = await ch.expect('payload', _stepTimeout);
  final Uint8List plain;
  try {
    plain = await open(theirKey, base64.decode(boxMsg['box'] as String));
  } catch (_) {
    throw PairingError(
      'the other device sent a payload that failed authentication — possible interception',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(plain));
  } on FormatException {
    throw PairingError('the other device sent a malformed payload');
  }
  if (decoded is! Map<String, dynamic>) {
    throw PairingError('the other device sent a malformed payload');
  }
  final payload = PairingPayload.fromJson(decoded);

  try {
    await apply(peer, payload, peerAddress);
  } catch (e) {
    ch.send({'t': 'done', 'ok': false, 'err': sanitizeName('$e')});
    rethrow;
  }
  ch.send({'t': 'done', 'ok': true});
  final done = await ch.expect('done', _applyTimeout);
  if (done['ok'] != true) {
    throw PairingError(
      'this machine now trusts ${peer.name}, but ${peer.name} failed to save the pairing: '
      '${sanitizeName(done['err'])}',
    );
  }
  return PairingOutcome(peer, payload, peerAddress);
}
