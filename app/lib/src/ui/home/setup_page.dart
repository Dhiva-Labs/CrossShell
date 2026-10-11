import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_controller.dart';
import '../../core/platform/local_system.dart';
import '../../core/ssh/ssh_files.dart';

/// "This machine": health checks, one-click fixes and settings.
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.app});
  final AppController app;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  bool _busy = false;
  String? _error;
  bool _firewall = true;
  bool _psDefault = true;
  String? _keyLine;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_changed);
    app.refreshHealth();
    app.files.ensureClientKey().then((k) {
      if (mounted) setState(() => _keyLine = k.line);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    app.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
      await app.refreshHealth();
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = app.health;
    final theme = Theme.of(context);
    final os = Platform.isWindows ? 'Windows' : 'Linux';
    return Scaffold(
      appBar: AppBar(title: const Text('This machine')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ListTile(
            leading: Icon(
              Platform.isWindows ? Icons.desktop_windows : Icons.computer,
              size: 36,
            ),
            title: Text(app.identity.name, style: theme.textTheme.titleLarge),
            subtitle: Text(
              '${LocalSystem.userName} · $os · ${h?.addresses.join(', ') ?? '…'}',
            ),
          ),
          const SizedBox(height: 8),
          if (_error != null)
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
                title: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _error = null),
                ),
              ),
            ),
          _section(context, 'Checks'),
          _check(
            ok: h?.sshServerRunning,
            title: 'SSH server',
            okText: h?.sshServerBanner ?? '',
            badText:
                'Not running — other machines can\'t sign in to this one yet. '
                'You can still connect out to machines that have it.',
            action: h?.sshServerRunning == false
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _firewall,
                        onChanged: (v) => setState(() => _firewall = v ?? true),
                        title: const Text(
                          'Allow SSH, pairing and discovery from the local network in the firewall',
                        ),
                      ),
                      if (Platform.isWindows)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: _psDefault,
                          onChanged: (v) =>
                              setState(() => _psDefault = v ?? true),
                          title: const Text(
                            'Use PowerShell as the SSH shell (instead of cmd.exe)',
                          ),
                        ),
                      const SizedBox(height: 6),
                      FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () => app.setUpSshServer(
                                  openFirewall: _firewall,
                                  powerShellDefault: _psDefault,
                                ),
                              ),
                        icon: const Icon(Icons.admin_panel_settings_outlined),
                        label: Text(
                          Platform.isWindows
                              ? 'Set up OpenSSH Server (admin prompt)'
                              : 'Install & enable openssh-server (password prompt)',
                        ),
                      ),
                    ],
                  )
                : null,
          ),
          _check(
            ok: h?.clientKeyReady,
            title: 'CrossShell SSH key',
            okText: SshLayout.configIdentityFile,
            badText: 'Could not create the key (is ssh-keygen installed?)',
          ),
          _check(
            ok: h == null ? null : h.discoveryError == null,
            title: 'Finding machines on the network',
            okText: 'Broadcasting on UDP 47820',
            badText: h?.discoveryError ?? '',
          ),
          _check(
            ok: h == null ? null : h.pairingError == null,
            title: 'Accepting pairing requests',
            okText: 'Listening on TCP 47820',
            badText: h?.pairingError ?? '',
          ),
          _check(
            ok: h == null ? null : h.agentPath != null && h.agentError == null,
            title: 'Screen sharing agent',
            okText: h?.agentPath ?? '',
            badText:
                h?.agentError ??
                'crossshell-host is missing from this installation',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(app.refreshHealth),
                icon: const Icon(Icons.refresh),
                label: const Text('Re-check'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(app.openFirewall),
                icon: const Icon(Icons.shield_outlined),
                label: const Text('Open firewall for the local network'),
              ),
            ],
          ),
          _section(context, 'Screen sharing'),
          SwitchListTile(
            value: app.settings.allowScreenSharing,
            onChanged: (v) async {
              app.settings.allowScreenSharing = v;
              await app.saveSettings();
            },
            title: const Text(
              'Let paired machines view and control this screen',
            ),
            subtitle: const Text(
              'Only machines you paired can connect, through SSH. '
              'You will see a banner while someone is watching.',
            ),
          ),
          _section(context, 'SSH'),
          ListTile(
            title: const Text('SSH port on this machine'),
            subtitle: const Text(
              'Change only if your sshd listens somewhere other than 22',
            ),
            trailing: SizedBox(
              width: 90,
              child: TextFormField(
                initialValue: '${app.settings.sshPort}',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onFieldSubmitted: (v) async {
                  final p = int.tryParse(v);
                  if (p != null && p > 0 && p < 65536) {
                    app.settings.sshPort = p;
                    await app.saveSettings();
                    await app.refreshHealth();
                  }
                },
              ),
            ),
          ),
          if (_keyLine != null)
            ListTile(
              title: const Text('This machine\'s CrossShell public key'),
              subtitle: SelectableText(
                _keyLine!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              trailing: IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: _keyLine!)),
              ),
            ),
          ListTile(
            title: const Text('Use your paired machines from any terminal'),
            subtitle: Text('ssh <name>   ·   managed in ${app.layout.config}'),
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _check({
    required bool? ok,
    required String title,
    required String okText,
    required String badText,
    Widget? action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: ok == null
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      ok ? Icons.check_circle : Icons.error,
                      color: ok ? Colors.green.shade600 : scheme.error,
                      size: 22,
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    ok == false ? badText : okText,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  if (action != null) ...[const SizedBox(height: 8), action],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
