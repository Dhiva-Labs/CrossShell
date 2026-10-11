import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../widgets/dialogs.dart';
import '../../widgets/error_banner.dart';
import '../session_controller.dart';
import '../session_types.dart';
import 'file_pane.dart';
import 'file_pane_controller.dart';
import 'fs_backend.dart';
import 'path_style.dart';
import 'sftp_backend.dart';
import 'transfer_engine.dart';
import 'transfer_panel.dart';
import 'transfer_queue.dart';

enum PaneSide { local, remote }

class _FileClipboard {
  const _FileClipboard(this.side, this.entries);
  final PaneSide side;
  final List<FsEntry> entries;
}

/// The Files tab: this computer on the left, the peer on the right, a
/// transfer queue underneath. Everything moves over SFTP on the shared SSH
/// connection.
class FilesTab extends StatefulWidget {
  const FilesTab({
    super.key,
    required this.session,
    required this.peerTitle,
    required this.os,
    required this.visible,
    this.localBackend,
    this.remoteBackendOpener,
    this.onOpenTerminalHere,
  });

  final SessionController session;
  final String peerTitle;
  final RemoteOs os;

  /// False while another page tab is in front.
  final bool visible;

  /// Test seam: a stand-in for the local disk.
  final FsBackend? localBackend;

  /// Test seam: opens the peer's filesystem (called once for browsing and
  /// once for the transfer channel) instead of using SFTP.
  final Future<FsBackend> Function()? remoteBackendOpener;

  /// Opens a terminal tab positioned in a remote folder (POSIX peers only).
  final void Function(String remoteDir)? onOpenTerminalHere;

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  late final FilePaneController _local;
  FilePaneController? _remote;
  final TransferQueue _queue = TransferQueue();
  StreamSubscription<TransferTask>? _finishedSub;

  FsBackend? _browse;
  Future<FsBackend>? _transferChannel;

  bool _remoteLoading = true;
  String? _remoteError;
  int _boundGeneration = -1;

  final FocusNode _localFocus = FocusNode(debugLabel: 'local pane');
  final FocusNode _remoteFocus = FocusNode(debugLabel: 'remote pane');
  PaneSide _active = PaneSide.local;
  _FileClipboard? _clipboard;
  bool _panelOpen = false;
  bool _osDropHover = false;

  SessionController get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _local = FilePaneController(
      backend: widget.localBackend ?? LocalFsBackend(),
    );
    unawaited(_local.init());
    _finishedSub = _queue.finished.listen(_onTaskFinished);
    _session.addListener(_onSessionChanged);
    if (_session.isConnected) {
      unawaited(_openRemote());
    } else {
      _remoteLoading = false;
    }
    if (widget.visible) _focusActive();
  }

  @override
  void didUpdateWidget(FilesTab old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) _focusActive();
  }

  void _focusActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.visible) return;
      (_active == PaneSide.local ? _localFocus : _remoteFocus).requestFocus();
    });
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _finishedSub?.cancel();
    _queue.dispose();
    _local.dispose();
    _remote?.removeListener(_remoteChanged);
    _remote?.dispose();
    unawaited(_browse?.close());
    final channel = _transferChannel;
    if (channel != null) {
      unawaited(channel.then((b) => b.close(), onError: (_) {}));
    }
    _localFocus.dispose();
    _remoteFocus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ remote

  Future<void> _openRemote() async {
    final gen = _session.generation;
    if (mounted) {
      setState(() {
        _remoteLoading = true;
        _remoteError = null;
      });
    }
    try {
      final FsBackend browse;
      final String home;
      final opener = widget.remoteBackendOpener;
      if (opener != null) {
        browse = await opener();
        home = await browse.home();
      } else {
        final client = _session.client;
        final sftp = await client.sftp();
        home = await sftp.absolute('.');
        if (!mounted || gen != _session.generation) {
          unawaited(sftp.close());
          return;
        }
        browse = SftpFsBackend(
          sftp,
          style: PathStyle.remote(widget.os, home: home),
          label: widget.peerTitle,
        );
      }
      if (!mounted || gen != _session.generation) {
        unawaited(browse.close());
        return;
      }
      // Channels of the previous connection are dead; drop them.
      unawaited(_browse?.close());
      _browse = browse;
      _transferChannel = null;
      if (_remote == null) {
        final pane = FilePaneController(
          backend: browse,
          initialPath: browse.style.normalize(home),
        );
        pane.addListener(_remoteChanged);
        _remote = pane;
        await pane.init();
      } else {
        await _remote!.rebind(browse);
      }
      _boundGeneration = gen;
      _remoteChanged();
    } catch (e) {
      _remoteError = e is SftpError || e is SSHError
          ? 'Could not open the file service on ${widget.peerTitle}: $e'
          : e.toString();
    } finally {
      if (mounted) setState(() => _remoteLoading = false);
    }
  }

  /// A second SFTP channel for transfers, so a big copy never makes browsing
  /// wait behind its in-flight requests.
  Future<FsBackend> _transferBackend() {
    final existing = _transferChannel;
    if (existing != null) return existing;
    final browse = _browse;
    if (browse == null) {
      return Future.error(
        const FsException('The peer\'s files are not available yet.'),
      );
    }
    final opener = widget.remoteBackendOpener;
    final future = () async {
      if (opener != null) return opener();
      final sftp = await _session.client.sftp();
      return SftpFsBackend(sftp, style: browse.style, label: widget.peerTitle);
    }();
    _transferChannel = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _) {
          // Let the next transfer try to open the channel again.
          if (identical(_transferChannel, future)) _transferChannel = null;
        },
      ),
    );
    return future;
  }

  void _remoteChanged() {
    final remote = _remote;
    if (remote != null && remote.cwd.isNotEmpty) {
      _session.remoteDir = remote.cwd;
    }
  }

  void _onSessionChanged() {
    if (!mounted) return;
    if (_session.phase == ConnectionPhase.connected &&
        _session.generation != _boundGeneration) {
      unawaited(_openRemote());
    } else {
      setState(() {});
    }
  }

  void _onTaskFinished(TransferTask task) {
    if (!mounted) return;
    if (task.status == TaskStatus.failed) {
      showToast(
        context,
        '${task.title}: ${task.error ?? 'failed'}',
        error: true,
      );
    }
    // Cheap relative to a transfer, and always correct whichever side changed.
    unawaited(_local.refresh());
    unawaited(_remote?.refresh());
  }

  // ----------------------------------------------------------- transfer

  FilePaneController? _pane(PaneSide side) =>
      side == PaneSide.local ? _local : _remote;

  Future<FsBackend> _backendFor(PaneSide side) async =>
      side == PaneSide.local ? _local.backend : await _transferBackend();

  void _setActive(PaneSide side) {
    if (_active != side) setState(() => _active = side);
  }

  void _switchPane() {
    final next = _active == PaneSide.local ? PaneSide.remote : PaneSide.local;
    setState(() => _active = next);
    (next == PaneSide.local ? _localFocus : _remoteFocus).requestFocus();
  }

  void _toast(String message, {bool error = false}) {
    if (mounted) showToast(context, message, error: error);
  }

  /// Moves [entries] from [from] into [destDir] on the other side, asking
  /// about name conflicts first.
  Future<void> _transfer(
    PaneSide from,
    List<FsEntry> entries, {
    String? destDir,
  }) async {
    if (entries.isEmpty) return;
    final to = from == PaneSide.local ? PaneSide.remote : PaneSide.local;
    final destPane = _pane(to);
    final fromPane = _pane(from);
    if (destPane == null || fromPane == null || !_session.isConnected) {
      _toast('Not connected to ${widget.peerTitle}.', error: true);
      return;
    }
    final target = destDir ?? destPane.cwd;
    if (target.isEmpty && !destPane.backend.style.isWindows) return;
    if (destPane.backend.style.isRoot(target) &&
        destPane.backend.style.isWindows) {
      _toast(
        'Open a drive or folder first: files cannot be placed in the drive list.',
        error: true,
      );
      return;
    }

    try {
      final destStyle = destPane.backend.style;
      final items = <CopyItem>[];
      final conflicts = <int>[];
      for (final entry in entries) {
        final name = destStyle.sanitizeName(entry.name);
        final existing = target == destPane.cwd
            ? destPane.entryNamed(name)
            : await destPane.backend.stat(destStyle.join(target, name));
        if (existing != null) conflicts.add(items.length);
        items.add(CopyItem(entry, name));
      }

      var policy = ConflictPolicy.overwrite;
      var finalItems = items;
      if (conflicts.isNotEmpty) {
        if (!mounted) return;
        final choice = await showConflictDialog(
          context,
          names: [for (final i in conflicts) items[i].destName],
          offerKeepBoth: true,
        );
        if (choice == ConflictChoice.cancel || !mounted) return;
        switch (choice) {
          case ConflictChoice.skip:
            policy = ConflictPolicy.skip;
          case ConflictChoice.keepBoth:
            // Every name in the destination folder counts, hidden ones too
            // (and the folder may not be the one the pane is showing).
            final existing = target == destPane.cwd
                ? destPane.allEntryNames
                : (await destPane.backend.list(target)).map((e) => e.name);
            // Compared case-insensitively: safe on a case-sensitive peer too.
            final taken = <String>{
              ...existing.map((n) => n.toLowerCase()),
              ...items.map((i) => i.destName.toLowerCase()),
            };
            finalItems = [
              for (var i = 0; i < items.length; i++)
                if (!conflicts.contains(i))
                  items[i]
                else
                  CopyItem(
                    items[i].source,
                    uniqueName(
                      items[i].destName,
                      (n) => taken.contains(n.toLowerCase()),
                      isDirectory: items[i].source.isDirectory,
                    ),
                  ),
            ];
          default:
            break;
        }
      }

      final fromBackend = await _backendFor(from);
      final toBackend = await _backendFor(to);
      final kind = from == PaneSide.local ? TaskKind.upload : TaskKind.download;
      final title = finalItems.length == 1
          ? finalItems.first.destName
          : '${finalItems.length} items';
      _queue.enqueue(
        kind: kind,
        title: title,
        subtitle:
            '${fromPane.backend.label}  →  ${destPane.backend.label}:  '
            '${destStyle.displayPath(target)}',
        runner: TransferEngine.copy(
          from: fromBackend,
          to: toBackend,
          items: finalItems,
          destDir: target,
          policy: policy,
        ),
      );
      if (mounted) setState(() => _panelOpen = true);
    } catch (e) {
      _toast(e.toString(), error: true);
    }
  }

  void _onDropped(PaneSide into, FileDragPayload payload, String destDir) {
    final from = into == PaneSide.local ? PaneSide.remote : PaneSide.local;
    unawaited(_transfer(from, payload.entries, destDir: destDir));
  }

  void _copyToClipboard(PaneSide side, List<FsEntry> entries) {
    setState(() => _clipboard = _FileClipboard(side, entries));
    _toast(
      '${entries.length == 1 ? entries.first.name : '${entries.length} items'} '
      'copied. Switch to the other pane (Tab) and press Ctrl+V.',
    );
  }

  void _paste(PaneSide into) {
    final clip = _clipboard;
    if (clip == null) {
      _toast('Nothing copied. Select files and press Ctrl+C first.');
      return;
    }
    if (clip.side == into) {
      _toast('Paste into the other pane: press Tab, then Ctrl+V.');
      return;
    }
    unawaited(_transfer(clip.side, clip.entries));
  }

  Future<void> _delete(PaneSide side, List<FsEntry> entries) async {
    final pane = _pane(side);
    if (pane == null || entries.isEmpty) return;
    final names = entries.take(6).map((e) => e.name).join('\n');
    final more = entries.length > 6
        ? '\n... and ${entries.length - 6} more'
        : '';
    final folders = entries.any((e) => e.isDirectory);
    final where = side == PaneSide.local ? 'this computer' : widget.peerTitle;
    final ok = await showConfirmDialog(
      context,
      title: entries.length == 1
          ? 'Delete "${entries.first.name}"?'
          : 'Delete ${entries.length} items?',
      message: '',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$names$more'),
          const SizedBox(height: 12),
          Text(
            'This permanently deletes ${folders ? 'the folders with everything in them' : 'the files'} '
            'from $where. There is no undo.',
          ),
        ],
      ),
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      final backend = await _backendFor(side);
      _queue.enqueue(
        kind: TaskKind.delete,
        title: entries.length == 1
            ? entries.first.name
            : '${entries.length} items',
        subtitle:
            '${pane.backend.label}:  ${pane.backend.style.displayPath(pane.cwd)}',
        runner: TransferEngine.delete(fs: backend, items: entries),
      );
      setState(() => _panelOpen = true);
    } catch (e) {
      _toast(e.toString(), error: true);
    }
  }

  // -------------------------------------------------------- file picking

  Future<void> _pickUploadFiles() async {
    try {
      final files = await openFiles();
      if (files.isEmpty) return;
      await uploadPaths([for (final f in files) f.path]);
    } catch (e) {
      _toast('Could not open the file picker: $e', error: true);
    }
  }

  Future<void> _pickUploadFolder() async {
    try {
      final dir = await getDirectoryPath(confirmButtonText: 'Upload');
      if (dir == null) return;
      await uploadPaths([dir]);
    } catch (e) {
      _toast('Could not open the folder picker: $e', error: true);
    }
  }

  Future<void> _chooseLocalFolder() async {
    try {
      final dir = await getDirectoryPath();
      if (dir != null) await _local.navigate(dir);
    } catch (e) {
      _toast('Could not open the folder picker: $e', error: true);
    }
  }

  /// Uploads local files or folders by absolute path into the remote pane's
  /// current folder.
  Future<void> uploadPaths(List<String> paths) async {
    final entries = <FsEntry>[];
    for (final path in paths) {
      try {
        final e = await _local.backend.stat(path);
        if (e != null) entries.add(e);
      } catch (e) {
        _toast(e.toString(), error: true);
      }
    }
    await _transfer(PaneSide.local, entries);
  }

  // --------------------------------------------------------------- build

  Widget _remotePane(BuildContext context) {
    final remote = _remote;
    if (remote == null) {
      return _RemoteUnavailable(
        loading: _remoteLoading,
        message:
            _remoteError ??
            (_session.isConnected
                ? null
                : _session.message ?? 'Not connected.'),
        peerTitle: widget.peerTitle,
        onRetry: _session.isConnected
            ? () => unawaited(_openRemote())
            : () => unawaited(_session.reconnect()),
      );
    }
    final offline = !_session.isConnected;
    final pane = FilePane(
      controller: remote,
      focusNode: _remoteFocus,
      title: widget.peerTitle,
      icon: widget.os == RemoteOs.windows
          ? Icons.laptop_windows
          : Icons.dns_outlined,
      active: _active == PaneSide.remote,
      transferLabel: 'Download',
      canPaste: _clipboard != null && _clipboard!.side != PaneSide.remote,
      onActivate: () => _setActive(PaneSide.remote),
      onTransfer: (e) => unawaited(_transfer(PaneSide.remote, e)),
      onDropped: (p, dir) => _onDropped(PaneSide.remote, p, dir),
      onDelete: (e) => unawaited(_delete(PaneSide.remote, e)),
      onCopy: (e) => _copyToClipboard(PaneSide.remote, e),
      onPaste: () => _paste(PaneSide.remote),
      onSwitchPane: _switchPane,
      statusBanner: offline
          ? InlineBanner(
              tone: BannerTone.warning,
              message: 'Connection to ${widget.peerTitle} lost.',
              actionLabel: 'Reconnect',
              onAction: () => unawaited(_session.reconnect()),
            )
          : _remoteError != null
          ? InlineBanner(
              message: _remoteError!,
              actionLabel: 'Try again',
              onAction: () => unawaited(_openRemote()),
            )
          : null,
      toolbarExtras: [
        PopupMenuButton<String>(
          tooltip: 'Upload from this computer',
          // A plain 30px box rather than the default 48px icon button, so the
          // toolbar is exactly as tall as the other pane's.
          padding: EdgeInsets.zero,
          child: const SizedBox(
            width: 30,
            height: 30,
            child: Icon(Icons.upload_file, size: 18),
          ),
          onSelected: (v) {
            if (v == 'files') unawaited(_pickUploadFiles());
            if (v == 'folder') unawaited(_pickUploadFolder());
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'files', child: Text('Upload files...')),
            PopupMenuItem(value: 'folder', child: Text('Upload folder...')),
          ],
        ),
      ],
      contextExtras: [
        if (widget.onOpenTerminalHere != null &&
            widget.os != RemoteOs.windows) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'terminal',
            onTap: () => widget.onOpenTerminalHere!(remote.cwd),
            child: const Text('Open terminal here'),
          ),
        ],
      ],
    );
    // Files dragged in from the OS file manager upload to the folder shown.
    return DropTarget(
      enable: !offline,
      onDragEntered: (_) => setState(() => _osDropHover = true),
      onDragExited: (_) => setState(() => _osDropHover = false),
      onDragDone: (details) {
        setState(() => _osDropHover = false);
        final paths = [
          for (final f in details.files)
            if (f.path.isNotEmpty) f.path,
        ];
        if (paths.isNotEmpty) unawaited(uploadPaths(paths));
      },
      child: Stack(
        children: [
          Positioned.fill(child: pane),
          if (_osDropHover)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.10),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(
                      'Drop to upload to ${widget.peerTitle}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localPane = FilePane(
      controller: _local,
      focusNode: _localFocus,
      title: 'This computer',
      icon: Icons.computer,
      active: _active == PaneSide.local,
      transferLabel: 'Upload',
      canPaste: _clipboard != null && _clipboard!.side != PaneSide.local,
      onActivate: () => _setActive(PaneSide.local),
      onTransfer: (e) => unawaited(_transfer(PaneSide.local, e)),
      onDropped: (p, dir) => _onDropped(PaneSide.local, p, dir),
      onDelete: (e) => unawaited(_delete(PaneSide.local, e)),
      onCopy: (e) => _copyToClipboard(PaneSide.local, e),
      onPaste: () => _paste(PaneSide.local),
      onSwitchPane: _switchPane,
      toolbarExtras: [
        PaneIconButton(
          icon: Icons.folder_open,
          tooltip: 'Choose folder...',
          onPressed: () => unawaited(_chooseLocalFolder()),
        ),
      ],
    );

    return ExcludeFocus(
      excluding: !widget.visible,
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: LayoutBuilder(
                builder: (context, box) {
                  final wide = box.maxWidth >= 820;
                  final buttons = _TransferButtons(
                    vertical: wide,
                    peerTitle: widget.peerTitle,
                    local: _local,
                    remote: _remote,
                    onUpload: () => unawaited(
                      _transfer(PaneSide.local, _local.selectedEntries),
                    ),
                    onDownload: () => unawaited(
                      _transfer(
                        PaneSide.remote,
                        _remote?.selectedEntries ?? const [],
                      ),
                    ),
                  );
                  final remotePane = _remotePane(context);
                  if (wide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: localPane),
                        buttons,
                        Expanded(child: remotePane),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: localPane),
                      buttons,
                      Expanded(child: remotePane),
                    ],
                  );
                },
              ),
            ),
          ),
          TransferPanel(
            queue: _queue,
            expanded: _panelOpen,
            onToggle: () => setState(() => _panelOpen = !_panelOpen),
          ),
        ],
      ),
    );
  }
}

class _TransferButtons extends StatelessWidget {
  const _TransferButtons({
    required this.vertical,
    required this.peerTitle,
    required this.local,
    required this.remote,
    required this.onUpload,
    required this.onDownload,
  });

  final bool vertical;
  final String peerTitle;
  final FilePaneController local;
  final FilePaneController? remote;
  final VoidCallback onUpload;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([local, ?remote]),
      builder: (context, _) {
        final canUpload = local.selection.isNotEmpty && remote != null;
        final canDownload = remote?.selection.isNotEmpty ?? false;
        final up = Tooltip(
          message: 'Upload selected to $peerTitle',
          child: IconButton.filledTonal(
            onPressed: canUpload ? onUpload : null,
            icon: Icon(vertical ? Icons.arrow_forward : Icons.arrow_downward),
          ),
        );
        final down = Tooltip(
          message: 'Download selected to this computer',
          child: IconButton.filledTonal(
            onPressed: canDownload ? onDownload : null,
            icon: Icon(vertical ? Icons.arrow_back : Icons.arrow_upward),
          ),
        );
        return Padding(
          padding: const EdgeInsets.all(6),
          child: vertical
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [up, const SizedBox(height: 10), down],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [up, const SizedBox(width: 10), down],
                ),
        );
      },
    );
  }
}

class _RemoteUnavailable extends StatelessWidget {
  const _RemoteUnavailable({
    required this.loading,
    required this.message,
    required this.peerTitle,
    required this.onRetry,
  });

  final bool loading;
  final String? message;
  final String peerTitle;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Center(
        child: loading
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 14),
                  Text('Opening $peerTitle...'),
                ],
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cloud_off_outlined,
                      size: 36,
                      color: scheme.outline,
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      message ?? 'The peer\'s files are not available.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.tonal(
                      onPressed: onRetry,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
