/// The app lock: nothing of the app is visible or reachable until the person
/// has passed the device's own prompt.
///
/// `design/README.md`: "Unlock with fingerprint or face (Touch ID on a Mac) …
/// Asked when the app opens and after 5 min in the background. Hidden when the
/// device has no biometrics."
///
/// The gate sits **above** the router, so a deep link lands behind it rather
/// than beside it: the locked app renders the lock screen and nothing else.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/preferences.dart';
import '../../data/providers.dart';
import '../../edition/edition.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';

/// How long the app may sit in the background before it locks again.
const Duration kLockAfterBackground = Duration(minutes: 5);

/// What the prompt is called on this platform.
///
/// The Mac has Touch ID and says so; a phone has whatever is enrolled, which
/// the design writes as "fingerprint or face".
bool get lockUsesTouchId =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

String get lockMethodLabel =>
    lockUsesTouchId ? 'Touch ID' : 'fingerprint or face';

/// "Unlock with fingerprint or face" / "Unlock with Touch ID".
String get lockSettingLabel => 'Unlock with $lockMethodLabel';

/// Whether the app is locked right now, and the clock that decides it.
class AppLockController extends StateNotifier<bool> {
  AppLockController({required bool enabled}) : super(enabled);

  /// When the app went to the background; null while it is in front.
  DateTime? _left;

  /// The app opened with the lock on, or it was just turned on and off again.
  void setEnabled(bool enabled) {
    if (!enabled) {
      _left = null;
      state = false;
    }
  }

  void unlock() {
    _left = null;
    state = false;
  }

  /// Called on every lifecycle change while the lock is on.
  void onLifecycle(AppLifecycleState lifecycle, {DateTime? now}) {
    final DateTime clock = now ?? DateTime.now();
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        final DateTime? left = _left;
        _left = null;
        if (left != null && clock.difference(left) >= kLockAfterBackground) {
          state = true;
        }
      case AppLifecycleState.inactive:
        // A permission sheet or the biometric prompt itself makes the app
        // inactive; that is not "in the background", so the clock ignores it.
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _left ??= clock;
    }
  }
}

final appLockProvider = StateNotifierProvider<AppLockController, bool>((ref) {
  // Read, not watch: the app locks because it **opened** with the lock on, or
  // because it came back from the background. Switching the preference on
  // mid-session must not lock the person out of the screen they just used —
  // they authenticated a moment ago to turn it on.
  final AppLockController controller = AppLockController(
    enabled: ref.read(preferencesProvider).appLock,
  );
  ref.listen<bool>(
    preferencesProvider.select((Preferences p) => p.appLock),
    (bool? _, bool enabled) => controller.setEnabled(enabled),
  );
  return controller;
});

/// Whether this device can run the prompt at all.
///
/// The whole Security section is hidden when it cannot, so nobody can lock
/// themselves out of a device that has no way back in.
final biometricsAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(authenticatorProvider).isAvailable(),
);

/// Wraps the whole app and shows the lock screen instead of it.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!ref.read(preferencesProvider).appLock) return;
    ref.read(appLockProvider.notifier).onLifecycle(state);
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = ref.watch(
      preferencesProvider.select((Preferences p) => p.appLock),
    );
    final bool locked = ref.watch(appLockProvider);
    if (!enabled || !locked) return widget.child;
    // The app is not merely covered: it is not built. Nothing behind the lock
    // screen is painted, scrolled, focused or reachable by a deep link.
    return const LockScreen();
  }
}

/// The brand mark, one line and one button.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  bool _busy = false;
  bool _refused = false;

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _refused = false;
    });
    final bool ok = await ref
        .read(authenticatorProvider)
        .confirm('Unlock Doomsaday');
    if (!mounted) return;
    setState(() {
      _busy = false;
      // A cancel or a failure leaves it locked, and says so rather than
      // pretending nothing happened.
      _refused = !ok;
    });
    if (ok) ref.read(appLockProvider.notifier).unlock();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Edition edition = ref.watch(editionProvider);
    return Scaffold(
      backgroundColor: t.ground,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: edition.isPro ? t.proRed : t.accent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'D',
                  style: TextStyle(
                    fontFamily: AppFonts.display,
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    color: edition.isPro ? t.proInk : t.onAccent,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Unlock Doomsaday',
                textAlign: TextAlign.center,
                style: AppText.sheetTitle.copyWith(color: t.text),
              ),
              const SizedBox(height: 8),
              Text(
                _refused
                    ? 'That did not unlock. Try $lockMethodLabel again.'
                    : 'Your servers stay out of sight until you unlock with '
                          '$lockMethodLabel.',
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(
                  color: _refused ? t.danger : t.mutedText,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              DoomButton(
                'Unlock',
                busy: _busy,
                tone: ButtonTone.primary,
                height: 52,
                radius: 16,
                onPressed: _unlock,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
