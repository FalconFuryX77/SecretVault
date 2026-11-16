import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_fonts.dart';

/// The vault's design tokens and building blocks (see docs/DESIGN.md).
///
/// One signal colour (amber), one destructive colour (red), warm greys for
/// everything else. Text is the system typeface; numbers and other data are
/// Fira Code. Grouped rows on one surface with hairlines, no cards per row,
/// no icon tiles, no gradients, no shadows.
class Ui {
  Ui._();

  // ─── Colour ──────────────────────────────────────────────────
  static const Color canvas = Color(0xFF0F0F0E);
  static const Color surface = Color(0xFF191917);
  static const Color raised = Color(0xFF23231F);
  static const Color hairline = Color(0xFF2D2C28);
  static const Color ink = Color(0xFFEDEAE3);
  static const Color ink2 = Color(0xFFA39F95);
  static const Color ink3 = Color(0xFF6F6B63);
  static const Color signal = Color(0xFFE8A33D);
  static const Color onSignal = Color(0xFF14110B);
  static const Color alert = Color(0xFFE5574F);

  // ─── Space ───────────────────────────────────────────────────
  static const double gutter = 20;
  static const double radius = 16;
  static const double control = 12;

  // ─── Type ────────────────────────────────────────────────────
  static TextStyle title({Color color = ink}) =>
      AppFonts.ui(fontSize: 28, fontWeight: FontWeight.w500, letterSpacing: -0.4, height: 1.15, color: color);
  static TextStyle heading({Color color = ink}) =>
      AppFonts.ui(fontSize: 20, fontWeight: FontWeight.w500, letterSpacing: -0.2, height: 1.2, color: color);
  static TextStyle label({Color color = ink2}) =>
      AppFonts.ui(fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0.1, color: color);
  static TextStyle body({Color color = ink, double size = 16}) =>
      AppFonts.ui(fontSize: size, fontWeight: FontWeight.w400, height: 1.35, color: color);
  static TextStyle detail({Color color = ink2}) =>
      AppFonts.ui(fontSize: 13, fontWeight: FontWeight.w400, height: 1.35, color: color);
  static TextStyle button({Color color = onSignal}) =>
      AppFonts.ui(fontSize: 15, fontWeight: FontWeight.w500, letterSpacing: 0.1, color: color);
  static TextStyle data({Color color = ink2, double size = 12, FontWeight weight = FontWeight.w400}) =>
      AppFonts.firaCode(fontSize: size, fontWeight: weight, color: color);

  /// A large number (the vault's size): system face, even-width figures.
  static TextStyle figure({Color color = ink, double size = 34}) => AppFonts.ui(
        fontSize: size,
        fontWeight: FontWeight.w300,
        letterSpacing: -0.6,
        height: 1.1,
        color: color,
      ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  /// The app's Material theme: every stock widget (dialogs, switches,
  /// snackbars, menus, progress, text fields) in these colours.
  static ThemeData theme() {
    const scheme = ColorScheme.dark(
      primary: signal,
      onPrimary: onSignal,
      secondary: signal,
      onSecondary: onSignal,
      error: alert,
      onError: canvas,
      surface: surface,
      onSurface: ink,
      onSurfaceVariant: ink2,
      outline: hairline,
      outlineVariant: hairline,
      surfaceContainerLowest: canvas,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: raised,
      surfaceContainerHighest: raised,
      inverseSurface: ink,
      onInverseSurface: canvas,
    );
    final base = ThemeData(useMaterial3: true, brightness: Brightness.dark, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      textTheme: AppFonts.uiTextTheme(base.textTheme).apply(bodyColor: ink, displayColor: ink),
      dividerColor: hairline,
      dividerTheme: const DividerThemeData(color: hairline, thickness: 0.6, space: 0.6),
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: ink,
        titleTextStyle: AppFonts.ui(fontSize: 18, fontWeight: FontWeight.w500, color: ink),
        iconTheme: const IconThemeData(color: ink, size: 22),
      ),
      iconTheme: const IconThemeData(color: ink2, size: 22),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: AppFonts.ui(fontSize: 20, fontWeight: FontWeight.w500, color: ink),
        contentTextStyle: AppFonts.ui(fontSize: 15, height: 1.45, color: ink2),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: hairline,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: AppFonts.ui(fontSize: 15, color: ink),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: raised,
        contentTextStyle: AppFonts.ui(fontSize: 14, height: 1.4, color: ink),
        actionTextColor: signal,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onSignal : ink2),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? signal : raised),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? signal : hairline),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: signal, linearTrackColor: raised, circularTrackColor: Colors.transparent),
      textSelectionTheme: const TextSelectionThemeData(cursorColor: signal, selectionColor: Color(0x55E8A33D), selectionHandleColor: signal),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: raised,
        hintStyle: AppFonts.ui(fontSize: 15, color: ink3),
        labelStyle: AppFonts.ui(fontSize: 15, color: ink2),
        floatingLabelStyle: AppFonts.ui(fontSize: 13, color: signal),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(control), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(control), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(control),
          borderSide: BorderSide(color: signal.withValues(alpha: 0.7), width: 1),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: signal, textStyle: AppFonts.ui(fontSize: 15, fontWeight: FontWeight.w500)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: signal,
          foregroundColor: onSignal,
          disabledBackgroundColor: raised,
          disabledForegroundColor: ink3,
          elevation: 0,
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(control)),
          textStyle: AppFonts.ui(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: signal,
        foregroundColor: onSignal,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        extendedTextStyle: AppFonts.ui(fontSize: 15, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: ink2,
        textColor: ink,
        titleTextStyle: AppFonts.ui(fontSize: 16, color: ink),
        subtitleTextStyle: AppFonts.ui(fontSize: 13, color: ink2, height: 1.35),
      ),
    );
  }

  /// A short, light tick for deliberate actions (never on every tap).
  static void tick() => HapticFeedback.selectionClick();
}

/// A labelled group of rows on one surface, divided by hairlines.
class UiGroup extends StatelessWidget {
  final String? label;
  final List<Widget> children;

  /// Where the hairlines start: past the icon when rows have one.
  final double dividerIndent;
  final EdgeInsetsGeometry margin;

  const UiGroup({
    super.key,
    this.label,
    required this.children,
    this.dividerIndent = 52,
    this.margin = const EdgeInsets.fromLTRB(Ui.gutter, 0, Ui.gutter, 24),
  });

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(Divider(height: 0.6, thickness: 0.6, indent: dividerIndent, color: Ui.hairline));
      rows.add(children[i]);
    }
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(label!, style: Ui.label()),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(Ui.radius),
            child: Material(color: Ui.surface, child: Column(children: rows)),
          ),
        ],
      ),
    );
  }
}

/// One row: an optional line icon (no tile), a title, optional detail, and
/// a trailing value, widget or chevron.
class UiRow extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? detail;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;
  final bool chevron;

  /// Optional key on the detail text (for tests that read a status line).
  final Key? detailKey;

  const UiRow({
    super.key,
    this.icon,
    required this.title,
    this.detail,
    this.value,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.chevron = true,
    this.detailKey,
  });

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? Ui.alert : Ui.ink;
    final end = trailing ??
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (value != null) Text(value!, style: Ui.data(size: 13)),
          if (onTap != null && chevron) ...[
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right_rounded, size: 20, color: Ui.ink3),
          ],
        ]);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: detail == null ? 56 : 68),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 21, color: destructive ? Ui.alert : Ui.ink2),
              const SizedBox(width: 15),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: Ui.body(color: fg)),
                  if (detail != null) ...[
                    const SizedBox(height: 3),
                    Text(detail!, key: detailKey, style: Ui.detail()),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            end,
          ]),
        ),
      ),
    );
  }
}

/// A row with a switch; the whole row toggles it.
class UiSwitchRow extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? detail;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? switchKey;
  final Key? detailKey;

  const UiSwitchRow({
    super.key,
    this.icon,
    required this.title,
    this.detail,
    required this.value,
    this.onChanged,
    this.switchKey,
    this.detailKey,
  });

  @override
  Widget build(BuildContext context) => UiRow(
        icon: icon,
        title: title,
        detail: detail,
        detailKey: detailKey,
        chevron: false,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: Switch(key: switchKey, value: value, onChanged: onChanged),
      );
}

/// The one full-width action at the bottom of a flow.
class UiPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  const UiPrimaryButton({super.key, required this.label, this.onPressed, this.busy = false});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: busy ? null : onPressed,
          child: busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Ui.ink3))
              : Text(label),
        ),
      );
}

/// Size of the vault by kind of file: large mono numerals, a thin split
/// bar in shades of ink, a one-line legend.
class UiMeter extends StatelessWidget {
  final String total;
  final String caption;
  final List<(String, int)> parts;
  const UiMeter({super.key, required this.total, required this.caption, required this.parts});

  static const _shades = [Ui.ink, Color(0xFFBDB9B0), Color(0xFF8E8A81), Color(0xFF615E57), Color(0xFF45433E)];

  @override
  Widget build(BuildContext context) {
    final sum = parts.fold<int>(0, (a, p) => a + p.$2);
    final shown = [for (final p in parts) if (p.$2 > 0) p];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(total, style: Ui.figure()),
          const SizedBox(width: 10),
          Text(caption, style: Ui.detail()),
        ]),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 4,
            child: sum == 0
                ? Container(color: Ui.raised)
                : Row(children: [
                    for (var i = 0; i < shown.length; i++) ...[
                      if (i > 0) const SizedBox(width: 2),
                      Expanded(
                        flex: (shown[i].$2 * 1000 ~/ sum).clamp(8, 1000),
                        child: Container(color: _shades[i % _shades.length]),
                      ),
                    ],
                  ]),
          ),
        ),
        if (shown.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 14, runSpacing: 6, children: [
            for (var i = 0; i < shown.length; i++)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 6, height: 6, decoration: BoxDecoration(color: _shades[i % _shades.length], shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(shown[i].$1, style: Ui.data(size: 11)),
              ]),
          ]),
        ],
      ],
    );
  }
}

/// Fades and lifts its child into place once, [index] steps after the
/// first (a staggered list). Respects "remove animations".
class UiEnter extends StatelessWidget {
  final Widget child;
  final int index;
  const UiEnter({super.key, required this.child, this.index = 0});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return child;
    final delay = (index.clamp(0, 10)) * 0.04;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 260 + (delay * 1000).round()),
      curve: Interval(delay / (0.26 + delay), 1, curve: Curves.easeOutCubic),
      builder: (_, t, c) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: c)),
      child: child,
    );
  }
}

/// A destructive action that has to be held: the bar fills in red while the
/// finger stays down and fires when it's full; letting go early cancels.
/// A slip under pressure can't destroy anything. A long press (also what
/// screen readers send) confirms at once.
class UiHoldButton extends StatefulWidget {
  final String label;
  final VoidCallback onConfirmed;
  final Duration duration;
  const UiHoldButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.duration = const Duration(milliseconds: 1100),
  });

  @override
  State<UiHoldButton> createState() => _UiHoldButtonState();
}

class _UiHoldButtonState extends State<UiHoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && !_done) _fire();
    });
  bool _done = false;

  void _fire() {
    _done = true;
    HapticFeedback.heavyImpact();
    widget.onConfirmed();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      onLongPress: () {
        if (!_done) _fire();
      },
      child: GestureDetector(
        onTapDown: (_) {
          Ui.tick();
          _c.forward();
        },
        onTapUp: (_) {
          if (!_done) _c.reverse();
        },
        onTapCancel: () {
          if (!_done) _c.reverse();
        },
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => ClipRRect(
            borderRadius: BorderRadius.circular(Ui.control),
            child: SizedBox(
              height: 52,
              child: Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Ui.raised),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _c.value,
                  child: const ColoredBox(color: Ui.alert),
                ),
                Center(
                  child: Text(
                    widget.label,
                    style: Ui.button(color: _c.value > 0.5 ? Ui.canvas : Ui.alert),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks to confirm something that destroys data: a short sheet with what
/// happens and a [UiHoldButton]. True if it was held to the end.
Future<bool> confirmByHolding(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Ui.gutter, 0, Ui.gutter, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Ui.heading()),
            const SizedBox(height: 10),
            Text(message, style: Ui.body(color: Ui.ink2, size: 15)),
            const SizedBox(height: 24),
            UiHoldButton(key: const Key('hold-confirm'), label: action, onConfirmed: () => Navigator.pop(ctx, true)),
            const SizedBox(height: 6),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel', style: TextStyle(color: Ui.ink2)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return ok == true;
}

/// A row of equal segments, like a hardware selector: the chosen one is
/// filled. [keyOf] (optional) keys each segment for tests.
class UiSegmented<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T>? onChanged;
  final String Function(T)? keyOf;
  const UiSegmented({super.key, required this.options, required this.selected, this.onChanged, this.keyOf});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Ui.raised, borderRadius: BorderRadius.circular(11)),
      child: Row(children: [
        for (final (value, label) in options)
          Expanded(
            child: GestureDetector(
              key: keyOf == null ? null : Key(keyOf!(value)),
              behavior: HitTestBehavior.opaque,
              onTap: onChanged == null
                  ? null
                  : () {
                      Ui.tick();
                      onChanged!(value);
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: value == selected ? Ui.ink : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  label,
                  style: Ui.body(size: 14, color: value == selected ? Ui.canvas : (onChanged == null ? Ui.ink3 : Ui.ink2)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
