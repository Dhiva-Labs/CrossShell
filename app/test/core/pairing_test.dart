import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_shell/src/core/pairing/pairing_crypto.dart';
import 'package:cross_shell/src/core/pairing/pairing_messages.dart';
import 'package:cross_shell/src/core/pairing/pairing_session.dart';
import 'package:flutter_test/flutter_test.dart';

// Real keys so payload validation passes.
const _edKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKKkY2WKzNp7LwHoUGCJxBB8MQrtp5MT5TMJtJ0xR0AU';
const _edKey2 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILGgJ19ugqnNH/jujnX9q/Xw1FzEAFi0hmISmyY/L9UF';

PairingPayload payload(String name, String os) => PairingPayload(
      sshUser: name == 'lenovo' ? 'dhiva' : 'dev user',
      sshPort: 22,
      hostKeys: [_edKey],
      clientKey: name == 'lenovo' ? _edKey : _edKey2,
      name: name,
      os: os,
    );

final linuxId = PeerIdentity(id: 'aaaaaaaa-1111-4111-8111-111111111111', name: 'desk', os: 'linux');
final winId = PeerIdentity(id: 'bbbbbbbb-2222-4222-8222-222222222222', name: 'lenovo', os: 'windows');

class _Run {
  _Run(this.initiator, this.responder, this.codes);
  final Future<PairingOutcome> initiator;
  final Future<PairingOutcome> responder;
  final List<String> codes;
}

Future<_Run> _pair({
  bool initiatorOk = true,
  bool responderOk = true,
  Future<void> Function(PeerIdentity, PairingPayload, String)? responderApply,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final codes = <String>[];
  final responderDone = Completer<PairingOutcome>();
  server.first.then((sock) {
    respondToPairing(
      socket: sock,
      me: winId,
      myPayload: payload('lenovo', 'windows'),
      confirm: (p) async {
        expect(p.incoming, isTrue);
        expect(p.peer.name, 'desk');
        codes.add(p.code);
        return responderOk;
      },
      apply: responderApply ?? (_, _, _) async {},
    ).then(responderDone.complete, onError: responderDone.completeError);
    server.close();
  });
  final initiator = initiatePairing(
    host: '127.0.0.1',
    port: server.port,
    me: linuxId,
    myPayload: payload('desk', 'linux'),
    confirm: (p) async {
      expect(p.incoming, isFalse);
      codes.add(p.code);
      return initiatorOk;
    },
    apply: (_, _, _) async {},
  );
  // Keep both futures observed so a failing side doesn't become an
  // unhandled error before the test inspects it.
  initiator.ignore();
  responderDone.future.ignore();
  return _Run(initiator, responderDone.future, codes);
}

void main() {
  test('both sides see the same code and get each other\'s payload', () async {
    final r = await _pair();
    final a = await r.initiator;
    final b = await r.responder;
    expect(r.codes, hasLength(2));
    expect(r.codes[0], r.codes[1]);
    expect(r.codes[0], matches(RegExp(r'^\d{3} \d{3}$')));
    expect(a.peer.id, winId.id);
    expect(a.payload.sshUser, 'dhiva');
    expect(a.payload.os, 'windows');
    expect(b.peer.id, linuxId.id);
    expect(b.payload.sshUser, 'dev user');
    expect(b.payload.clientKey, _edKey2);
    expect(a.peerAddress, '127.0.0.1');
  });

  test('a rejected code fails both sides', () async {
    final r = await _pair(responderOk: false);
    await expectLater(r.initiator, throwsA(isA<PairingError>()));
    await expectLater(r.responder, throwsA(isA<PairingError>()));
  });

  test('initiator rejection fails both sides', () async {
    final r = await _pair(initiatorOk: false);
    await expectLater(r.initiator, throwsA(isA<PairingError>()));
    await expectLater(r.responder, throwsA(isA<PairingError>()));
  });

  test('a failed apply on one side is reported to the other', () async {
    final r = await _pair(responderApply: (_, _, _) async => throw Exception('UAC declined'));
    await expectLater(
      r.initiator,
      throwsA(isA<PairingError>().having((e) => e.message, 'message', contains('failed to save'))),
    );
    await expectLater(r.responder, throwsA(anything));
  });

  test('a commitment mismatch is detected by the responder', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final result = server.first.then((sock) => respondToPairing(
          socket: sock,
          me: winId,
          myPayload: payload('lenovo', 'windows'),
          confirm: (_) async => fail('must not reach the code prompt'),
          apply: (_, _, _) async => fail('must not apply'),
        ));
    result.ignore();
    // A cheating initiator: commits to one key, reveals another.
    final sock = await Socket.connect('127.0.0.1', server.port);
    final ch = FrameChannel(sock);
    final real = await Ephemeral.generate();
    final other = await Ephemeral.generate();
    final nonce = randomBytes(32);
    ch.send({
      't': 'hello',
      'v': 1,
      ...linuxId.toJson(),
      'commit': base64.encode(await commitment(real.publicKey, nonce)),
    });
    await ch.expect('key', const Duration(seconds: 5));
    ch.send({'t': 'reveal', 'pk': base64.encode(other.publicKey), 'nonce': base64.encode(nonce)});
    await expectLater(result, throwsA(isA<PairingError>().having((e) => e.message, 'm', contains('commitment'))));
    await ch.close();
    await server.close();
  });

  group('crypto', () {
    test('seal/open round trip and tamper detection', () async {
      final a = await Ephemeral.generate();
      final b = await Ephemeral.generate();
      final ss1 = await a.sharedSecret(b.publicKey);
      final ss2 = await b.sharedSecret(a.publicKey);
      expect(ss1, ss2);
      final th = randomBytes(32);
      final k = await deriveKey(ss1, th, keyInfoInitiator);
      final sealed = await seal(k, utf8.encode('hello'));
      expect(utf8.decode(await open(await deriveKey(ss2, th, keyInfoInitiator), sealed)), 'hello');
      sealed[sealed.length - 1] ^= 1;
      await expectLater(open(k, sealed), throwsA(anything));
      // Direction keys differ.
      final kR = await deriveKey(ss1, th, keyInfoResponder);
      await expectLater(open(kR, await seal(k, [1, 2, 3])), throwsA(anything));
    });

    test('transcript binds ids unambiguously', () async {
      final pk = randomBytes(32);
      final n = randomBytes(32);
      final t1 = await transcriptHash(pkI: pk, pkR: pk, nonceI: n, idI: 'ab', idR: 'c');
      final t2 = await transcriptHash(pkI: pk, pkR: pk, nonceI: n, idI: 'a', idR: 'bc');
      expect(t1, isNot(t2));
    });

    test('sas formatting', () {
      expect(formatSas(7), '000 007');
      expect(formatSas(482913), '482 913');
    });

    test('low-order peer keys are refused', () async {
      final a = await Ephemeral.generate();
      await expectLater(a.sharedSecret(randomBytes(31)), throwsA(isA<FormatException>()));
      await expectLater(a.sharedSecret(Uint8List(32)), throwsA(anything));
    });
  });

  group('payload validation', () {
    Map<String, dynamic> good() => payload('desk', 'linux').toJson();

    test('accepts a good payload', () {
      expect(PairingPayload.fromJson(good()).sshPort, 22);
    });

    test('rejects key injection and bad fields', () {
      for (final bad in <Map<String, dynamic>>[
        {...good(), 'clientKey': 'command="rm -rf /" $_edKey'},
        {...good(), 'clientKey': '$_edKey\nssh-ed25519 AAAA'},
        {...good(), 'clientKey': 'ssh-ed25519 AAAAC3NzaC1yc2E='},
        {...good(), 'hostKeys': ['ssh-dss AAAA']},
        {...good(), 'sshUser': 'a"b'},
        {...good(), 'sshUser': 'a\nb'},
        {...good(), 'sshUser': ''},
        {...good(), 'sshPort': 0},
        {...good(), 'sshPort': '22'},
      ]) {
        expect(() => PairingPayload.fromJson(bad), throwsA(isA<PairingError>()), reason: '$bad');
      }
    });
  });
}
