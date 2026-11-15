import 'package:flutter/widgets.dart';

/// The app's root navigator.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Route names that mark the vault's own screens (lock screen, setup, the
/// vault itself). Everything the vault pushes sits above one of these.
const String vaultRoutePrefix = 'vault/';

/// Tracks the root navigator's routes, so locking can remove every vault
/// screen at once, without a transition.
class VaultRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> stack = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => stack.add(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => stack.remove(route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => stack.remove(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : stack.indexOf(oldRoute);
    if (i >= 0 && newRoute != null) {
      stack[i] = newRoute;
    } else if (newRoute != null) {
      stack.add(newRoute);
    }
  }

  /// Removes everything above the first route (the cover app), without a
  /// transition, so the very next frame is the cover app: popUntil animates
  /// each route out, and that animation would show the vault.
  void removeAllAboveFirst() => _removeFrom(1);

  /// Removes the first vault screen and everything above it, leaving the
  /// cover app's own screens alone.
  void removeVaultScreens() {
    final i = stack.indexWhere((r) => (r.settings.name ?? '').startsWith(vaultRoutePrefix));
    if (i >= 0) _removeFrom(i);
  }

  void _removeFrom(int index) {
    final nav = rootNavigatorKey.currentState;
    if (nav == null || index >= stack.length) return;
    for (final r in stack.sublist(index).reversed) {
      // A route already popping (e.g. popUntil just ran) is no longer
      // active; removing it still stops its exit animation.
      if (r.navigator != null) nav.removeRoute(r);
    }
  }
}

final VaultRouteObserver vaultRoutes = VaultRouteObserver();
