// LAN discovery: UDP broadcast beacons on port 47820 (PLAN.md "Discovery").
//
// Beacons are unauthenticated hints. They are only ever used to *find* a
// machine; trust comes from pairing and the pinned SSH host key, so a
// spoofed beacon can at worst make a connection attempt fail.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const discoveryPort = 47820;
const beaconInterval = Duration(seconds: 3);
const beaconExpiry = Duration(seconds: 10);
const _maxBeacon = 2048;

class Beacon {
  Beacon({
    required this.id,
    required this.name,
    required this.os,
    required this.user,
    required this.sshPort,
    required this.pairPort,
    required this.version,
  });

  final String id;
  final String name;
  final String os;
  final String user;
  final int sshPort;
  final int pairPort;
  final String version;

  Map<String, dynamic> toJson() => {
    'cs': 1,
    'id': id,
    'name': name,
    'os': os,
    'user': user,
    'sshPort': sshPort,
    'pairPort': pairPort,
    'ver': version,
  };

  static Beacon? tryParse(List<int> data) {
    if (data.length > _maxBeacon) return null;
    try {
      final m = jsonDecode(utf8.decode(data));
      if (m is! Map<String, dynamic> || m['cs'] != 1 || m['q'] != null) {
        return null;
      }
      final id = m['id'];
      final sshPort = m['sshPort'];
      final pairPort = m['pairPort'];
      if (id is! String || !RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(id)) {
        return null;
      }
      if (sshPort is! int || sshPort < 1 || sshPort > 65535) return null;
      if (pairPort is! int || pairPort < 1 || pairPort > 65535) return null;
      String str(Object? v, int max) {
        final s = (v is String ? v : '').replaceAll(
          RegExp(r'[\x00-\x1f\x7f]'),
          '',
        );
        return s.length > max ? s.substring(0, max) : s;
      }

      return Beacon(
        id: id,
        name: str(m['name'], 64),
        os: switch (m['os']) {
          'linux' || 'windows' || 'macos' => m['os'] as String,
          _ => 'other',
        },
        user: str(m['user'], 104),
        sshPort: sshPort,
        pairPort: pairPort,
        version: str(m['ver'], 32),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A machine seen on the LAN recently.
class SeenPeer {
  SeenPeer(this.beacon, this.address, this.lastSeen);
  final Beacon beacon;
  final String address;
  final DateTime lastSeen;
}

class Discovery {
  Discovery(this._self);

  Beacon _self;
  RawDatagramSocket? _socket;
  Timer? _timer;
  final _seen = <String, SeenPeer>{};
  final _changes = StreamController<List<SeenPeer>>.broadcast();
  String? error;

  /// Fires whenever the set of visible machines changes (or one moves IP).
  Stream<List<SeenPeer>> get changes => _changes.stream;

  List<SeenPeer> get visible {
    final cutoff = DateTime.now().subtract(beaconExpiry);
    return _seen.values.where((s) => s.lastSeen.isAfter(cutoff)).toList()
      ..sort((a, b) => a.beacon.name.compareTo(b.beacon.name));
  }

  void updateSelf(Beacon b) => _self = b;

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
    } on SocketException catch (e) {
      error =
          'Discovery unavailable (UDP $discoveryPort busy?): ${e.osError?.message ?? e.message}';
      return;
    }
    _socket!
      ..broadcastEnabled = true
      ..listen(_onEvent);
    await _broadcast();
    _timer = Timer.periodic(beaconInterval, (_) {
      _broadcast();
      _expire();
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _socket?.close();
    _socket = null;
  }

  /// Ask a specific address to answer with its beacon (manual "add by IP").
  void query(String address) {
    _socket?.send(
      utf8.encode(jsonEncode({'cs': 1, 'q': 1})),
      InternetAddress(address),
      discoveryPort,
    );
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    // A query: answer with our beacon, unicast.
    try {
      final m = jsonDecode(utf8.decode(dg.data));
      if (m is Map && m['cs'] == 1 && m['q'] == 1) {
        _socket?.send(
          utf8.encode(jsonEncode(_self.toJson())),
          dg.address,
          dg.port,
        );
        return;
      }
    } catch (_) {
      return;
    }
    final b = Beacon.tryParse(dg.data);
    if (b == null || b.id == _self.id) return;
    final prev = _seen[b.id];
    _seen[b.id] = SeenPeer(b, dg.address.address, DateTime.now());
    if (prev == null ||
        prev.address != dg.address.address ||
        prev.beacon.name != b.name) {
      _changes.add(visible);
    }
  }

  void _expire() {
    final before = visible.length;
    final cutoff = DateTime.now().subtract(beaconExpiry * 6);
    _seen.removeWhere((_, s) => s.lastSeen.isBefore(cutoff));
    if (visible.length != before) _changes.add(visible);
  }

  Future<void> _broadcast() async {
    final s = _socket;
    if (s == null) return;
    final data = utf8.encode(jsonEncode(_self.toJson()));
    for (final target in await broadcastTargets()) {
      try {
        s.send(data, target, discoveryPort);
      } catch (_) {
        // Some interfaces refuse broadcast; ignore them.
      }
    }
  }
}

/// 255.255.255.255 plus the /24 directed broadcast of each private IPv4
/// interface (dart:io doesn't expose netmasks; /24 covers home LANs, and
/// the limited broadcast covers the rest on the default route).
Future<List<InternetAddress>> broadcastTargets() async {
  final out = <String>{'255.255.255.255'};
  try {
    for (final ni in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in ni.addresses) {
        final o = a.rawAddress;
        if (a.isLoopback || a.isLinkLocal || !isPrivateIPv4(o)) continue;
        out.add('${o[0]}.${o[1]}.${o[2]}.255');
      }
    }
  } catch (_) {}
  return out.map(InternetAddress.new).toList();
}

bool isPrivateIPv4(List<int> o) =>
    o.length == 4 &&
    (o[0] == 10 ||
        (o[0] == 172 && o[1] >= 16 && o[1] < 32) ||
        (o[0] == 192 && o[1] == 168) ||
        (o[0] == 100 &&
            o[1] >= 64 &&
            o[1] < 128)); // CGNAT range: Tailscale & co.

/// This machine's private LAN IPv4 addresses (for display).
Future<List<String>> localAddresses() async {
  final out = <String>[];
  try {
    for (final ni in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      if (ni.name.startsWith('docker') ||
          ni.name.startsWith('br-') ||
          ni.name.startsWith('veth') ||
          ni.name.startsWith('lxd')) {
        continue;
      }
      for (final a in ni.addresses) {
        if (!a.isLoopback && isPrivateIPv4(a.rawAddress)) out.add(a.address);
      }
    }
  } catch (_) {}
  return out;
}
