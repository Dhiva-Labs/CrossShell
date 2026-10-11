// Ties the core together for the UI: identity, paired peers, discovery,
// the pairing listener, SSH setup and remote desktop.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'discovery/discovery.dart';
import 'pairing/pairing_messages.dart';
import 'pairing/pairing_session.dart';
import 'peers/peer.dart';
import 'platform/local_system.dart';
import 'remote_desktop/local_agent.dart';
import 'remote_desktop/remote_commands.dart';
import 'remote_desktop/remote_desktop.dart';
import 'ssh/public_key.dart';
import 'ssh/setup_scripts.dart';
import 'ssh/ssh_connect.dart';
import 'ssh/ssh_files.dart';
import 'ssh/sshd.dart';

const appVersion = '0.1.0';
const pairingPort = 47820;

class AppSettings {
  AppSettings({this.sshPort = 22, this.allowScreenSharing = true});
  int sshPort;

  /// Keep the screen-share agent running so paired machines can view and
  /// control this screen.
  bool allowScreenSharing;

  Map<String, dynamic> toJson() => {'sshPort': sshPort, 'allowScreenSharing': allowScreenSharing};

  factory AppSettings.fromJson(Map<String, dynamic> m) => AppSettings(
        sshPort: (m['sshPort'] as int?) ?? 22,
        allowScreenSharing: m['allowScreenSharing'] as bool? ?? true,
      );
}

/// Result of the local health check.
class LocalHealth {
  LocalHealth({
    required this.sshServerBanner,
    required this.clientKeyReady,
    required this.discoveryError,
    required this.pairingError,
    required this.agentPath,
    required this.addresses,
  });
  final String? sshServerBanner;
  final bool clientKeyReady;
  final String? discoveryError;
  final String? pairingError;
  final String? agentPath;
  final List<String> addresses;

  bool get sshServerRunning => sshServerBanner != null;
}

/// Shown when the UI must ask the user to compare pairing codes.
typedef PairingPromptHandler = Future<bool> Function(PairingPrompt prompt);

class AppController extends ChangeNotifier {
  AppController();

  late final String appDir;
  late final DeviceIdentity identity;
  late final PeerStore _store;
  late AppSettings settings;
  final layout = SshLayout.forUser();
  late final SshFiles files = SshFiles(layout);
  late final Discovery discovery;
  final localAgent = LocalAgent();

  List<Peer> peers = [];
  List<SeenPeer> seen = [];
  LocalHealth? health;
  WatchStatus? watching;
  String? pairingError;
  bool _pairingBusy = false;
  ServerSocket? _pairServer;
  final _sessions = <String, RemoteDesktopSession>{};

  /// Set by the UI; incoming pairing requests are declined while null.
  PairingPromptHandler? promptHandler;

  /// Called after an incoming pairing completes or fails (for a snackbar).
  void Function(String message, {bool error})? onNotice;

  bool _ready = false;
  bool get ready => _ready;

  /// Machines on the LAN that are not paired yet.
  List<SeenPeer> get unpaired => seen.where((s) => !peers.any((p) => p.id == s.beacon.id)).toList();

  bool isOnline(Peer peer) => seen.any((s) => s.beacon.id == peer.id);

  Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    appDir = support.path;
    await ensurePrivateDir(appDir);
    identity = await DeviceIdentity.load(appDir);
    _store = PeerStore(File(p.join(appDir, 'peers.json')));
    peers = await _store.load();
    settings = await _loadSettings();

    discovery = Discovery(_beacon());
    await discovery.start();
    discovery.changes.listen(_onSeen);

    await _startPairingServer();

    await localAgent.publishPath();
    if (settings.allowScreenSharing) await localAgent.ensureRunning();
    localAgent.status.listen((s) {
      watching = s;
      notifyListeners();
    });
    localAgent.startWatching();

    _ready = true;
    notifyListeners();
    unawaited(refreshHealth());
  }

  Beacon _beacon() => Beacon(
        id: identity.id,
        name: identity.name,
        os: LocalSystem.osName,
        user: LocalSystem.userName,
        sshPort: settings.sshPort,
        pairPort: pairingPort,
        version: appVersion,
      );

  Future<AppSettings> _loadSettings() async {
    final f = File(p.join(appDir, 'settings.json'));
    try {
      if (await f.exists()) return AppSettings.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {}
    return AppSettings();
  }

  Future<void> saveSettings() async {
    await writePrivateFile(p.join(appDir, 'settings.json'), jsonEncode(settings.toJson()));
    discovery.updateSelf(_beacon());
    if (settings.allowScreenSharing) {
      await localAgent.ensureRunning();
    } else {
      await localAgent.stop();
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ discovery

  Future<void> _onSeen(List<SeenPeer> list) async {
    seen = list;
    // Follow paired peers to new addresses (DHCP). Trust is unaffected:
    // the host key stays pinned.
    for (final s in list) {
      final i = peers.indexWhere((p) => p.id == s.beacon.id);
      if (i >= 0 && peers[i].lastIp != s.address) {
        peers[i] = peers[i].copyWith(lastIp: s.address);
        await _store.save(peers);
        if (peers[i].canConnect) await files.writePeerConfig(_entry(peers[i]));
      }
    }
    notifyListeners();
  }

  PeerSshEntry _entry(Peer p) =>
      PeerSshEntry(peerId: p.id, alias: p.alias, host: p.lastIp, port: p.sshPort, user: p.sshUser);

  // ------------------------------------------------------------- health

  Future<void> refreshHealth() async {
    final banner = await probeSshBanner('127.0.0.1', settings.sshPort);
    var keyReady = false;
    try {
      await files.ensureClientKey();
      keyReady = true;
    } catch (_) {}
    health = LocalHealth(
      sshServerBanner: banner,
      clientKeyReady: keyReady,
      discoveryError: discovery.error,
      pairingError: pairingError,
      agentPath: localAgent.agentPath,
      addresses: await localAddresses(),
    );
    notifyListeners();
  }

  /// Install/enable this machine's SSH server (one admin prompt).
  Future<void> setUpSshServer({bool openFirewall = true, bool powerShellDefault = true}) async {
    if (Platform.isWindows) {
      await runWindowsElevated([
        InstallSshServer(),
        if (openFirewall) OpenFirewall(settings.sshPort),
        if (powerShellDefault) PowerShellDefaultShell(),
      ]);
    } else if (Platform.isLinux) {
      await runLinuxPrivileged('install-server');
      if (openFirewall) await runLinuxPrivileged('firewall', ['${settings.sshPort}']);
    } else {
      throw SetupError('Automatic setup is not supported on this OS');
    }
    await refreshHealth();
  }

  Future<void> openFirewall() async {
    if (Platform.isWindows) {
      await runWindowsElevated([OpenFirewall(settings.sshPort)]);
    } else if (Platform.isLinux) {
      await runLinuxPrivileged('firewall', ['${settings.sshPort}']);
    }
  }

  // ------------------------------------------------------------- pairing

  Future<void> _startPairingServer() async {
    try {
      _pairServer = await ServerSocket.bind(InternetAddress.anyIPv4, pairingPort);
      _pairServer!.listen(_onPairingConnection);
    } on SocketException catch (e) {
      pairingError = 'Cannot listen for pairing on TCP $pairingPort: ${e.osError?.message ?? e.message}';
    }
  }

  Future<void> _onPairingConnection(Socket socket) async {
    final handler = promptHandler;
    if (_pairingBusy || handler == null) {
      rejectBusy(socket);
      return;
    }
    _pairingBusy = true;
    try {
      final outcome = await respondToPairing(
        socket: socket,
        me: _me(),
        myPayload: await _myPayload(),
        confirm: handler,
        apply: _applyPeer,
      );
      onNotice?.call('Paired with ${outcome.peer.name}');
    } on PairingError catch (e) {
      onNotice?.call('Pairing failed: ${e.message}', error: true);
    } catch (e) {
      onNotice?.call('Pairing failed: $e', error: true);
    } finally {
      _pairingBusy = false;
    }
  }

  PeerIdentity _me() => PeerIdentity(id: identity.id, name: identity.name, os: LocalSystem.osName);

  Future<PairingPayload> _myPayload() async {
    final clientKey = await files.ensureClientKey();
    final banner = await probeSshBanner('127.0.0.1', settings.sshPort);
    final hostKeys = banner == null ? <PublicKey>[] : await localHostKeys(settings.sshPort);
    return PairingPayload(
      sshUser: LocalSystem.userName,
      sshPort: settings.sshPort,
      hostKeys: [for (final k in hostKeys) k.line],
      clientKey: clientKey.line,
      name: identity.name,
      os: LocalSystem.osName,
    );
  }

  /// Pair with a machine at [address] (from discovery or typed by the user).
  Future<Peer> pairWith(String address, {int port = pairingPort}) async {
    if (_pairingBusy) throw PairingError('Already pairing');
    final handler = promptHandler;
    if (handler == null) throw PairingError('UI not ready');
    _pairingBusy = true;
    try {
      final outcome = await initiatePairing(
        host: address,
        port: port,
        me: _me(),
        myPayload: await _myPayload(),
        confirm: handler,
        apply: _applyPeer,
      );
      return peers.firstWhere((p) => p.id == outcome.peer.id);
    } finally {
      _pairingBusy = false;
    }
  }

  Future<void> _applyPeer(PeerIdentity peer, PairingPayload payload, String address) async {
    final mine = await probeSshBanner('127.0.0.1', settings.sshPort) != null;
    final existing = peers.where((p) => p.id == peer.id).firstOrNull;
    final alias = existing?.alias ??
        makeAlias(payload.name, peers.where((p) => p.id != peer.id).map((p) => p.alias));

    // Let them in (only meaningful while we run an SSH server).
    if (mine) {
      final key = PublicKey.parse(payload.clientKey);
      if (await LocalSystem.isWindowsAdmin()) {
        await runWindowsElevated([AuthorizeAdminKey(peer.id, key)]);
      } else {
        await files.authorizeInUserFile(peer.id, key);
      }
    }
    final record = Peer(
      id: peer.id,
      name: payload.name,
      os: payload.os,
      alias: alias,
      sshUser: payload.sshUser,
      sshPort: payload.sshPort,
      hostKeys: payload.hostKeys,
      clientKey: payload.clientKey,
      lastIp: address,
      pairedAt: DateTime.now(),
    );
    // Pin them.
    if (record.canConnect) {
      await files.pinHostKeys(peer.id, [for (final k in payload.hostKeys) PublicKey.parse(k)]);
      await files.writePeerConfig(_entry(record));
    }
    peers = [...peers.where((p) => p.id != peer.id), record]..sort((a, b) => a.name.compareTo(b.name));
    await _store.save(peers);
    notifyListeners();
  }

  /// Forget [peer] here and, if reachable, remove our key over there too.
  Future<void> unpair(Peer peer) async {
    if (peer.canConnect) {
      try {
        await runOnPeer(layout, peer, revokeSelfCommand(windows: peer.isWindows, myId: identity.id),
            timeout: const Duration(seconds: 15));
      } catch (_) {
        // Offline: our key stays there until they unpair us.
      }
    }
    if (await LocalSystem.isWindowsAdmin()) {
      try {
        await runWindowsElevated([RevokeAdminKey(peer.id)]);
      } on SetupError {
        // Fall through: still remove it from the per-user file and our records.
      }
    }
    await files.revokeInUserFile(peer.id);
    await files.removePeerConfig(peer.id);
    await files.pinHostKeys(peer.id, const []);
    peers = peers.where((p) => p.id != peer.id).toList();
    await _store.save(peers);
    notifyListeners();
  }

  // ------------------------------------------------------- using a peer

  Future<SSHClient> connect(Peer peer) => connectToPeer(peer, files);

  /// Check reachability and key auth through the system ssh.
  Future<String> checkPeer(Peer peer) async {
    final banner = await probeSshBanner(peer.lastIp, peer.sshPort);
    if (banner == null) return 'No SSH server answering at ${peer.lastIp}:${peer.sshPort}';
    try {
      await runOnPeer(layout, peer, peer.isWindows ? 'cmd /c echo ok' : 'echo ok', timeout: const Duration(seconds: 15));
      return 'OK — $banner';
    } on Exception catch (e) {
      return 'SSH answered ($banner) but login failed: $e';
    }
  }

  Future<RemoteDesktopSession> openRemoteDesktop(
    Peer peer, {
    bool viewOnly = false,
    void Function(String)? onStatus,
  }) async {
    _sessions[peer.id]?.close();
    final s = await RemoteDesktopSession.start(peer, layout, viewOnly: viewOnly, onStatus: onStatus);
    _sessions[peer.id] = s;
    unawaited(s.done.then((_) => _sessions.remove(peer.id)));
    return s;
  }

  /// Open `ssh <alias>` in the OS terminal.
  Future<void> openSystemTerminal(Peer peer) async {
    final ssh = LocalSystem.sshTool('ssh');
    final args = ['-F', layout.config, peer.alias];
    if (Platform.isWindows) {
      try {
        await Process.start('wt.exe', [ssh, ...args], mode: ProcessStartMode.detached);
      } on ProcessException {
        await Process.start('cmd.exe', ['/c', 'start', 'CrossShell', ssh, ...args], mode: ProcessStartMode.detached);
      }
      return;
    }
    for (final term in [
      ['x-terminal-emulator', '-e'],
      ['gnome-terminal', '--'],
      ['ptyxis', '--'],
      ['konsole', '-e'],
      ['xfce4-terminal', '-x'],
      ['kitty'],
      ['alacritty', '-e'],
      ['xterm', '-e'],
    ]) {
      try {
        await Process.start(term.first, [...term.skip(1), ssh, ...args], mode: ProcessStartMode.detached);
        return;
      } on ProcessException {
        continue;
      }
    }
    throw ProcessException('terminal', const [], 'No terminal emulator found');
  }

  /// Open VS Code Remote-SSH on [peer] at [remotePath].
  Future<void> openVsCode(Peer peer, String remotePath) async {
    // VS Code reads ~/.ssh/config, which includes ours.
    final path = peer.isWindows && RegExp(r'^/[A-Za-z]:').hasMatch(remotePath) ? remotePath.substring(1) : remotePath;
    try {
      await Process.start(Platform.isWindows ? 'code.cmd' : 'code', ['--remote', 'ssh-remote+${peer.alias}', path],
          mode: ProcessStartMode.detached, runInShell: Platform.isWindows);
    } on ProcessException {
      throw ProcessException('code', const [], 'VS Code (the "code" command) was not found');
    }
  }

  @override
  void dispose() {
    for (final s in _sessions.values) {
      s.close();
    }
    discovery.stop();
    _pairServer?.close();
    localAgent.dispose();
    super.dispose();
  }
}
