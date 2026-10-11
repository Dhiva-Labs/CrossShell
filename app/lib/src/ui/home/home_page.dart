import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/discovery/discovery.dart';
import '../../core/pairing/pairing_messages.dart';
import '../../core/peers/peer.dart';
import '../../core/remote_desktop/remote_desktop.dart';
import '../session/session_page.dart';
import 'pairing_dialog.dart';
import 'setup_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.app});
  final AppController app;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppController get app => widget.app;
  final _rdStatus = <String, String>{};

  @override
  void initState() {
    super.initState();
    app.addListener(_changed);
    app.promptHandler = (prompt) => showPairingCodeDialog(context, prompt);
    app.onNotice = (msg, {error = false}) => _snack(msg, error: error);
  }

  @override
  void dispose() {
    app.removeListener(_changed);
    app.promptHandler = null;
    app.onNotice = null;
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? scheme.error : null,
        duration: Duration(seconds: error ? 8 : 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _pair(String address, String label) async {
    try {
      final peer = await app.pairWith(address);
      _snack('Paired with ${peer.name}. From any terminal: ssh ${peer.alias}');
    } on PairingError catch (e) {
      _snack('Pairing with $label failed: ${e.message}', error: true);
    } catch (e) {
      _snack('Pairing with $label failed: $e', error: true);
    }
  }

  void _openSession(Peer peer, SessionTab tab) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(
          peerId: peer.id,
          title: peer.name,
          os: peer.isWindows
              ? RemoteOs.windows
              : (peer.os == 'linux' ? RemoteOs.linux : RemoteOs.other),
          connect: () => app.connect(peer),
          initialTab: tab,
          onRemoteDesktop: () => _remoteDesktop(peer),
          onOpenSystemTerminal: () =>
              _guard(() => app.openSystemTerminal(peer)),
          onOpenVsCode: (path) => _guard(() => app.openVsCode(peer, path)),
        ),
      ),
    );
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      _snack('$e', error: true);
    }
  }

  Future<void> _remoteDesktop(Peer peer, {bool viewOnly = false}) async {
    setState(() => _rdStatus[peer.id] = 'Connecting…');
    try {
      final s = await app.openRemoteDesktop(
        peer,
        viewOnly: viewOnly,
        onStatus: (m) => setState(() => _rdStatus[peer.id] = m),
      );
      setState(() => _rdStatus[peer.id] = 'Opening viewer…');
      s.events.listen((ev) {
        if (!mounted) return;
        switch (ev.kind) {
          case 'waiting':
            setState(
              () => _rdStatus[peer.id] =
                  ev.message ?? 'Waiting for ${peer.name}…',
            );
          case 'connected':
            setState(
              () => _rdStatus[peer.id] = viewOnly ? 'Viewing' : 'Controlling',
            );
          case 'closed':
            final reason = ev.message;
            if (reason != null && reason.isNotEmpty && reason != 'user') {
              _snack('Remote desktop: $reason', error: true);
            }
          case 'exited':
            setState(() => _rdStatus.remove(peer.id));
        }
      });
    } on RemoteDesktopError catch (e) {
      setState(() => _rdStatus.remove(peer.id));
      _snack(e.message, error: true);
    } catch (e) {
      setState(() => _rdStatus.remove(peer.id));
      _snack('Remote desktop failed: $e', error: true);
    }
  }

  Future<void> _unpair(Peer peer) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unpair ${peer.name}?'),
        content: Text(
          'This removes ${peer.name}\'s key from this machine and, if ${peer.name} is reachable, '
          'this machine\'s key from ${peer.name}. You can pair again any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _guard(() async {
      await app.unpair(peer);
      _snack('Unpaired ${peer.name}');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = app.health;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.swap_horiz_rounded, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            const Text('CrossShell'),
          ],
        ),
        actions: [
          if (h != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                avatar: Icon(
                  Icons.computer,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                label: Text(
                  '${app.identity.name} · ${h.addresses.isEmpty ? 'offline' : h.addresses.first}',
                ),
              ),
            ),
          IconButton(
            tooltip: 'This machine',
            icon: Badge(
              isLabelVisible: h != null && !h.sshServerRunning,
              smallSize: 9,
              child: const Icon(Icons.settings_outlined),
            ),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => SetupPage(app: app)),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (app.watching != null) _watchingBanner(theme),
          if (h != null && !h.sshServerRunning) _setupBanner(theme),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                _header(theme, 'Your machines', null),
                if (app.peers.isEmpty)
                  _empty(
                    theme,
                    'No paired machines yet',
                    'Open CrossShell on your other computer, then pair with it from Nearby below.',
                  ),
                for (final p in app.peers) _peerCard(theme, p),
                const SizedBox(height: 20),
                _header(
                  theme,
                  'Nearby',
                  TextButton.icon(
                    onPressed: () async {
                      final addr = await askPairAddress(context);
                      if (addr != null && addr.isNotEmpty) {
                        await _pair(addr, addr);
                      }
                    },
                    icon: const Icon(Icons.add_link),
                    label: const Text('Pair by address'),
                  ),
                ),
                if (app.unpaired.isEmpty)
                  _empty(
                    theme,
                    'Looking for CrossShell on your network…',
                    'Machines running CrossShell on the same network show up here.',
                    searching: true,
                  ),
                for (final s in app.unpaired) _nearbyCard(theme, s),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _watchingBanner(ThemeData theme) {
    final w = app.watching!;
    return MaterialBanner(
      backgroundColor: theme.colorScheme.tertiaryContainer,
      leading: Icon(
        Icons.screen_share,
        color: theme.colorScheme.onTertiaryContainer,
      ),
      content: Text(
        '${w.viewer} is ${w.viewOnly ? 'viewing' : 'viewing and controlling'} this screen',
        style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await app.localAgent.stop();
            if (app.settings.allowScreenSharing) {
              await Future<void>.delayed(const Duration(milliseconds: 500));
              await app.localAgent.ensureRunning();
            }
          },
          child: const Text('Disconnect them'),
        ),
      ],
    );
  }

  Widget _setupBanner(ThemeData theme) => MaterialBanner(
    leading: const Icon(Icons.info_outline),
    content: const Text(
      'Other machines can\'t sign in to this one yet: its SSH server is not running.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => SetupPage(app: app))),
        child: const Text('Set up'),
      ),
    ],
  );

  Widget _header(ThemeData theme, String title, Widget? trailing) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
    child: Row(
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const Spacer(),
        ?trailing,
      ],
    ),
  );

  Widget _empty(
    ThemeData theme,
    String title,
    String body, {
    bool searching = false,
  }) => Card(
    elevation: 0,
    color: theme.colorScheme.surfaceContainerLow,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          if (searching)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              Icons.devices_other,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  IconData _osIcon(String os) => switch (os) {
    'windows' => Icons.window,
    'linux' => Icons.terminal,
    'macos' => Icons.laptop_mac,
    _ => Icons.computer,
  };

  Widget _peerCard(ThemeData theme, Peer p) {
    final online = app.isOnline(p);
    final rd = _rdStatus[p.id];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(radius: 22, child: Icon(_osIcon(p.os))),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: online
                          ? Colors.green.shade500
                          : theme.colorScheme.outline,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.colorScheme.surface,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    rd ??
                        (p.canConnect
                            ? 'ssh ${p.alias}  ·  ${p.sshUser}@${p.lastIp}${online ? '' : '  ·  not seen on the network'}'
                            : '${p.name} has no SSH server — it can connect to this machine, not the other way'),
                    style: TextStyle(
                      color: rd != null
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (p.canConnect) ...[
              _action(
                Icons.terminal,
                'Terminal',
                () => _openSession(p, SessionTab.terminal),
              ),
              _action(
                Icons.folder_open,
                'Files',
                () => _openSession(p, SessionTab.files),
              ),
              _action(
                Icons.desktop_windows_outlined,
                'Remote desktop',
                rd != null ? null : () => _remoteDesktop(p),
              ),
            ],
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) async {
                switch (v) {
                  case 'view':
                    await _remoteDesktop(p, viewOnly: true);
                  case 'forwards':
                    _openSession(p, SessionTab.forwards);
                  case 'sys':
                    await _guard(() => app.openSystemTerminal(p));
                  case 'code':
                    await _guard(
                      () => app.openVsCode(
                        p,
                        p.isWindows
                            ? '/C:/Users/${p.sshUser}'
                            : '/home/${p.sshUser}',
                      ),
                    );
                  case 'check':
                    _snack('Checking ${p.name}…');
                    final r = await app.checkPeer(p);
                    _snack('${p.name}: $r', error: !r.startsWith('OK'));
                  case 'unpair':
                    await _unpair(p);
                }
              },
              itemBuilder: (_) => [
                if (p.canConnect) ...[
                  const PopupMenuItem(
                    value: 'view',
                    child: ListTile(
                      leading: Icon(Icons.visibility_outlined),
                      title: Text('View screen only'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'forwards',
                    child: ListTile(
                      leading: Icon(Icons.swap_calls),
                      title: Text('Port forwards'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'sys',
                    child: ListTile(
                      leading: Icon(Icons.open_in_new),
                      title: Text('Open in system terminal'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'code',
                    child: ListTile(
                      leading: Icon(Icons.code),
                      title: Text('Open in VS Code'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'check',
                    child: ListTile(
                      leading: Icon(Icons.network_check),
                      title: Text('Check connection'),
                    ),
                  ),
                  const PopupMenuDivider(),
                ],
                const PopupMenuItem(
                  value: 'unpair',
                  child: ListTile(
                    leading: Icon(Icons.link_off),
                    title: Text('Unpair'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(IconData icon, String tooltip, VoidCallback? onPressed) =>
      IconButton(tooltip: tooltip, icon: Icon(icon), onPressed: onPressed);

  Widget _nearbyCard(ThemeData theme, SeenPeer s) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
      leading: CircleAvatar(child: Icon(_osIcon(s.beacon.os))),
      title: Text(s.beacon.name),
      subtitle: Text(
        '${s.beacon.user} · ${s.address} · CrossShell ${s.beacon.version}',
      ),
      trailing: FilledButton.tonalIcon(
        onPressed: () => _pair(s.address, s.beacon.name),
        icon: const Icon(Icons.link),
        label: const Text('Pair'),
      ),
    ),
  );
}
