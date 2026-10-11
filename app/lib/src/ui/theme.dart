import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

/// Semantic colours the Material scheme has no slot for.
@immutable
class CrossShellColors extends ThemeExtension<CrossShellColors> {
  const CrossShellColors({
    required this.success,
    required this.warning,
    required this.info,
    required this.terminal,
  });

  final Color success;
  final Color warning;
  final Color info;

  /// Palette of the terminal view.
  final TerminalTheme terminal;

  @override
  CrossShellColors copyWith({
    Color? success,
    Color? warning,
    Color? info,
    TerminalTheme? terminal,
  }) => CrossShellColors(
    success: success ?? this.success,
    warning: warning ?? this.warning,
    info: info ?? this.info,
    terminal: terminal ?? this.terminal,
  );

  @override
  CrossShellColors lerp(ThemeExtension<CrossShellColors>? other, double t) {
    if (other is! CrossShellColors) return this;
    return CrossShellColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      terminal: t < 0.5 ? terminal : other.terminal,
    );
  }

  static CrossShellColors of(BuildContext context) =>
      Theme.of(context).extension<CrossShellColors>() ?? _lightColors;
}

/// Monospace families tried in order. Flutter resolves each by name through
/// the platform font system, so the first one installed wins; the generic
/// `monospace` is the last resort and always exists.
const List<String> terminalFontFamilies = [
  'JetBrains Mono',
  'Cascadia Mono',
  'Cascadia Code',
  'Fira Code',
  'Source Code Pro',
  'Hack',
  'DejaVu Sans Mono',
  'Ubuntu Mono',
  'Liberation Mono',
  'Noto Sans Mono',
  'Consolas',
  'Menlo',
  'Monaco',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK JP',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'Segoe UI Symbol',
  'Segoe UI Emoji',
  'monospace',
];

const Color _seed = Color(0xFF2F6B8E);

const TerminalTheme _darkTerminal = TerminalTheme(
  cursor: Color(0xFFD7DEE6),
  selection: Color(0x664F7CAC),
  foreground: Color(0xFFD7DEE6),
  background: Color(0xFF14181D),
  black: Color(0xFF1B2128),
  red: Color(0xFFE06C75),
  green: Color(0xFF8CC17D),
  yellow: Color(0xFFE5C07B),
  blue: Color(0xFF61AFEF),
  magenta: Color(0xFFC678DD),
  cyan: Color(0xFF56B6C2),
  white: Color(0xFFC5CCD3),
  brightBlack: Color(0xFF5C6773),
  brightRed: Color(0xFFF28B93),
  brightGreen: Color(0xFFA9D99B),
  brightYellow: Color(0xFFF0D399),
  brightBlue: Color(0xFF82C0F5),
  brightMagenta: Color(0xFFD99AEA),
  brightCyan: Color(0xFF7CCBD5),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFE5C07B),
  searchHitBackgroundCurrent: Color(0xFFF28B93),
  searchHitForeground: Color(0xFF14181D),
);

const TerminalTheme _lightTerminal = TerminalTheme(
  cursor: Color(0xFF2B3138),
  selection: Color(0x553B82C4),
  foreground: Color(0xFF2B3138),
  background: Color(0xFFFBFCFD),
  black: Color(0xFF2B3138),
  red: Color(0xFFC62F3C),
  green: Color(0xFF3E8A3A),
  yellow: Color(0xFF9A6E00),
  blue: Color(0xFF1F63B5),
  magenta: Color(0xFF9033B0),
  cyan: Color(0xFF117C8C),
  white: Color(0xFFD5DADF),
  brightBlack: Color(0xFF6A7580),
  brightRed: Color(0xFFE0505C),
  brightGreen: Color(0xFF58A752),
  brightYellow: Color(0xFFB88500),
  brightBlue: Color(0xFF3F82D6),
  brightMagenta: Color(0xFFB255D0),
  brightCyan: Color(0xFF2F9AAB),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFFE08A),
  searchHitBackgroundCurrent: Color(0xFFFFB0B6),
  searchHitForeground: Color(0xFF2B3138),
);

const CrossShellColors _lightColors = CrossShellColors(
  success: Color(0xFF2E7D4F),
  warning: Color(0xFF9A6A00),
  info: Color(0xFF2F6B8E),
  terminal: _lightTerminal,
);

const CrossShellColors _darkColors = CrossShellColors(
  success: Color(0xFF7BCB98),
  warning: Color(0xFFE5B95A),
  info: Color(0xFF8DC3E3),
  terminal: _darkTerminal,
);

ThemeData _build(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final isDark = brightness == Brightness.dark;
  final outline = scheme.outlineVariant;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: scheme.surface,
    dividerTheme: DividerThemeData(color: outline, space: 1, thickness: 1),
    extensions: [isDark ? _darkColors : _lightColors],
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: outline),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: outline),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbVisibility: const WidgetStatePropertyAll(false),
      radius: const Radius.circular(4),
      thickness: const WidgetStatePropertyAll(8),
      thumbColor: WidgetStatePropertyAll(
        scheme.onSurfaceVariant.withValues(alpha: 0.35),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 460,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    listTileTheme: const ListTileThemeData(dense: true),
  );
}

ThemeData buildLightTheme() => _build(Brightness.light);

ThemeData buildDarkTheme() => _build(Brightness.dark);
