import 'dart:math';

enum ForwardKind {
  /// `ssh -L`: a port on this computer reaches a host:port on the peer's side.
  local,

  /// `ssh -R`: a port on the peer reaches a host:port on this computer.
  remote,
}

/// Ports people forward most often. Order is the order of the chips.
const List<({int port, String hint})> commonDevPorts = [
  (port: 3000, hint: 'Node / React'),
  (port: 4200, hint: 'Angular'),
  (port: 5173, hint: 'Vite'),
  (port: 8000, hint: 'Django / http.server'),
  (port: 8080, hint: 'HTTP alt'),
  (port: 5432, hint: 'PostgreSQL'),
];

/// One saved forward.
///
/// "Bind" is where connections are accepted, "target" is where they are sent:
///  * local:  bind = this computer, target = a host:port the peer can reach.
///  * remote: bind = the peer,      target = a host:port this computer can reach.
class ForwardRule {
  const ForwardRule({
    required this.id,
    required this.kind,
    required this.bindHost,
    required this.bindPort,
    required this.targetHost,
    required this.targetPort,
    this.label = '',
  });

  final String id;
  final ForwardKind kind;
  final String label;
  final String bindHost;
  final int bindPort;
  final String targetHost;
  final int targetPort;

  factory ForwardRule.create({
    required ForwardKind kind,
    required int bindPort,
    required int targetPort,
    String? bindHost,
    String targetHost = 'localhost',
    String label = '',
  }) => ForwardRule(
    id: newId(),
    kind: kind,
    label: label,
    bindHost:
        bindHost ?? (kind == ForwardKind.local ? '127.0.0.1' : 'localhost'),
    bindPort: bindPort,
    targetHost: targetHost,
    targetPort: targetPort,
  );

  /// A one-click preset: the same port on both ends.
  factory ForwardRule.devPort(
    int port,
    ForwardKind kind, {
    String label = '',
  }) => ForwardRule.create(
    kind: kind,
    bindPort: port,
    targetPort: port,
    label: label,
  );

  ForwardRule copyWith({
    ForwardKind? kind,
    String? label,
    String? bindHost,
    int? bindPort,
    String? targetHost,
    int? targetPort,
  }) => ForwardRule(
    id: id,
    kind: kind ?? this.kind,
    label: label ?? this.label,
    bindHost: bindHost ?? this.bindHost,
    bindPort: bindPort ?? this.bindPort,
    targetHost: targetHost ?? this.targetHost,
    targetPort: targetPort ?? this.targetPort,
  );

  /// Same listener and destination, ignoring label and id.
  bool sameRoute(ForwardRule other) =>
      kind == other.kind &&
      bindHost == other.bindHost &&
      bindPort == other.bindPort &&
      targetHost == other.targetHost &&
      targetPort == other.targetPort;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'label': label,
    'bindHost': bindHost,
    'bindPort': bindPort,
    'targetHost': targetHost,
    'targetPort': targetPort,
  };

  /// Tolerant on purpose: a hand-edited file with one bad entry must not
  /// lose the others. Returns null for an entry that cannot be used.
  static ForwardRule? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final kind = ForwardKind.values.asNameMap()[json['kind']];
    final bindPort = json['bindPort'];
    final targetPort = json['targetPort'];
    final bindHost = json['bindHost'];
    final targetHost = json['targetHost'];
    if (id is! String || id.isEmpty || kind == null) return null;
    if (bindPort is! int || targetPort is! int) return null;
    if (bindHost is! String || targetHost is! String) return null;
    final rule = ForwardRule(
      id: id,
      kind: kind,
      label: json['label'] is String ? json['label'] as String : '',
      bindHost: bindHost,
      bindPort: bindPort,
      targetHost: targetHost,
      targetPort: targetPort,
    );
    return rule.validate() == null ? rule : null;
  }

  /// A sentence describing what is wrong with this rule, or null.
  String? validate() {
    if (!_validPort(bindPort)) return 'The listening port must be 1-65535.';
    if (!_validPort(targetPort)) return 'The destination port must be 1-65535.';
    if (bindHost.trim().isEmpty) return 'The listening address is empty.';
    if (targetHost.trim().isEmpty) return 'The destination host is empty.';
    return null;
  }

  static bool _validPort(int p) => p >= 1 && p <= 65535;

  /// "127.0.0.1:3000 -> localhost:3000".
  String get route => '$bindHost:$bindPort  →  $targetHost:$targetPort';

  String get title => label.isNotEmpty
      ? label
      : (kind == ForwardKind.local
            ? 'Port $bindPort'
            : 'Port $bindPort (reverse)');

  static final Random _rng = Random.secure();

  static String newId() {
    final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Parses a port field. Null for empty or out-of-range input.
int? parsePort(String text) {
  final value = int.tryParse(text.trim());
  if (value == null || value < 1 || value > 65535) return null;
  return value;
}
