import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/app/account_exit_controller.dart';
import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/app/pending_photo_exit.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/security/biometric_auth_service.dart';
import 'package:scheduling/core/theme/button_styles.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/settings/application/app_lock_provider.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

/// App-wide biometric gate. Covers the app on cold start, and again whenever
/// it returns from the background.
class AppLock extends ConsumerStatefulWidget {
  const AppLock({required this.child, this.navigatorKey, super.key});

  final Widget child;

  /// The Navigator BELOW the overlay, which Log out lands on login; without
  /// it the escape is not offered.
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  ConsumerState<AppLock> createState() => _AppLockState();
}

class _AppLockState extends ConsumerState<AppLock> with WidgetsBindingObserver {
  bool _locked = false;
  bool _authenticating = false;
  bool _exiting = false;

  /// Biometrics reported unavailable while locked; the overlay says so inline
  /// and offers Continue, a session-only release that never persists.
  bool _unavailable = false;

  /// True when [_locked] was taken because the flag was UNRESOLVED rather than
  /// because it is on. Resume clears such a lock once the retry settles, so a
  /// user who never opted in can't be trapped behind a biometric prompt they
  /// may have no way to satisfy.
  bool _lockedUnresolved = false;

  /// Log out's pending-photo choice, asked inline: a dialog would open on the
  /// Navigator under this opaque overlay.
  int? _pendingPhotoCount;
  Completer<bool>? _photoChoice;

  /// A failed Log out's composed notice, inline for the same reason.
  String? _logOutError;

  StreamSubscription<void>? _loginShownSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final logger = ref.read(loggerProvider);
    // A forced exit's login holds nothing to guard; drop the lock once it covers the app.
    _loginShownSub = ref.read(forcedExitLoginShownProvider).stream.listen(
      (_) {
        if (mounted && _locked) _release();
      },
      onError: (Object e, StackTrace st) =>
          logger.warn('APPLOCK loginShown stream failed', e, st),
    );
    _lockOnStartIfEnabled();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_loginShownSub?.cancel());
    _answerPhotoChoice(discard: false);
    super.dispose();
  }

  /// Resolves the flag through the controller — the ONE reader of the stored
  /// value, so the widget and the Settings switch can't disagree about it.
  Future<void> _lockOnStartIfEnabled() async {
    final controller = ref.read(appLockEnabledProvider.notifier);
    await controller.ensureLoaded();
    if (!mounted) return;
    if (!controller.isResolved) {
      setState(() {
        _locked = true;
        _lockedUnresolved = true;
      });
      unawaited(controller.retryIfUnresolved().then((_) => _afterRetry()));
      return;
    }
    _lockIfEnabled();
  }

  void _lockIfEnabled() {
    if (_locked || !ref.read(appLockEnabledProvider)) return;
    setState(() => _locked = true);
    unawaited(_authenticate());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(appLockEnabledProvider.notifier);
    if (state == AppLifecycleState.resumed) {
      // Retry BEFORE deciding: an unresolved flag can still settle on `true` (ADR-0016).
      if (!controller.isResolved) {
        unawaited(controller.retryIfUnresolved().then((_) => _afterRetry()));
        return;
      }
      if (_locked) unawaited(_authenticate());
      return;
    }
    // Backgrounding: an UNRESOLVED flag locks too. This is the gate the OS
    // grabs its app-switcher snapshot behind, so "we don't know yet" must not
    // read as "no lock" — that was the same fail-open the resume path above
    // closes, just at the other end. Resume releases it if it settles `false`.
    if (controller.isResolved && !ref.read(appLockEnabledProvider)) return;
    // Lock on `inactive` too, since that's the state the OS grabs its
    // app-switcher snapshot during.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (!_locked) {
        setState(() {
          _locked = true;
          _lockedUnresolved = !controller.isResolved;
        });
      }
    }
  }

  /// Settles the lock after a resume-time retry of an unresolved flag.
  ///
  /// A retry that still can't read the flag RELEASES a defensive lock rather
  /// than holding it: the snapshot window it existed for has passed, and a
  /// persistent storage fault must never leave the app unusable for someone
  /// who never enabled biometrics. So a durable read failure still degrades to
  /// "unlocked" — the win here is that it no longer does so while the app sits
  /// in the switcher.
  void _afterRetry() {
    if (!mounted) return;
    if (!ref.read(appLockEnabledProvider)) {
      if (_lockedUnresolved) _release();
      return;
    }
    _lockedUnresolved = false;
    if (_locked) {
      unawaited(_authenticate());
    } else {
      _lockIfEnabled();
    }
  }

  void _release() {
    // An unlock while the photo choice is up answers it as Stay.
    _answerPhotoChoice(discard: false);
    setState(() {
      _locked = false;
      _lockedUnresolved = false;
      _unavailable = false;
      _logOutError = null;
    });
  }

  Future<void> _authenticate() async {
    if (_authenticating || !mounted) return;
    _authenticating = true;
    // Riverpod 3 throws on `ref.read` from an unmounted consumer, so every
    // provider this path needs is resolved before the first await.
    final logger = ref.read(loggerProvider);
    final service = ref.read(biometricAuthServiceProvider);
    try {
      final available = await service.isAvailable();
      if (!mounted) return;
      if (!available) {
        // Inline on the overlay, never persisted: `isAvailable()` is false in the pre-first-unlock window.
        logger.warn(
          'APPLOCK unavailable after lock engaged; offering Continue',
        );
        if (!_unavailable) setState(() => _unavailable = true);
        return;
      }
      // Biometrics are back: withdraw Continue before the prompt is up.
      if (_unavailable) setState(() => _unavailable = false);

      final reason = context.l10n.applock_reason;
      final ok = await service.authenticate(reason);
      if (ok && mounted) _release();
    } catch (e, st) {
      logger.warn('APPLOCK authenticate flow failed', e, st);
    } finally {
      _authenticating = false;
    }
  }

  /// The same voluntary sign-out as Settings (`signOutAfterPhotoCheck`), its
  /// teardown under the forced-exit guard so the two can't interleave; the
  /// lock drops once nobody is signed in.
  Future<void> _logOut() async {
    final navigatorKey = widget.navigatorKey;
    if (_exiting || navigatorKey == null) return;
    // Riverpod 3 throws on `ref.read` from an unmounted consumer.
    final logger = ref.read(loggerProvider);
    final auth = ref.read(authServiceProvider);
    final analytics = ref.read(analyticsServiceProvider);
    final exit = ref.read(accountExitControllerProvider);
    setState(() {
      _exiting = true;
      _logOutError = null;
    });
    var signedOut = false;
    try {
      signedOut = await signOutAfterPhotoCheck(
        context,
        DeviceDeregistrationDeps.from(ref.read),
        auth,
        analytics,
        prompt: _askAboutPendingPhotos,
        guard: exit.runVoluntaryTeardown,
      );
    } catch (e, st) {
      logger.warn('ACCT-SIGNOUT app lock signOut failed', e, st);
      if (!mounted) return;
      setState(() {
        _exiting = false;
        _logOutError = composeErrorNotice(
          context,
          intro: context.l10n.error_introSignOut,
          error: e,
        );
      });
      return;
    }
    if (!mounted) return;
    setState(() => _exiting = false);
    if (!signedOut && auth.currentUser != null) return;
    _release();
    try {
      navigatorKey.currentState?.pushNamedAndRemoveUntil(
        AppRoutes.login,
        (_) => false,
      );
    } catch (e, st) {
      logger.warn('ACCT-SIGNOUT navigation failed', e, st);
    }
  }

  Future<bool> _askAboutPendingPhotos(int count) {
    _answerPhotoChoice(discard: false);
    final choice = _photoChoice = Completer<bool>();
    if (mounted) setState(() => _pendingPhotoCount = count);
    return choice.future;
  }

  void _answerPhotoChoice({required bool discard}) {
    final choice = _photoChoice;
    if (choice == null) return;
    _photoChoice = null;
    _pendingPhotoCount = null;
    if (!choice.isCompleted) choice.complete(discard);
  }

  void _onPhotoChoice({required bool discard}) =>
      setState(() => _answerPhotoChoice(discard: discard));

  @override
  Widget build(BuildContext context) {
    final canLogOut = widget.navigatorKey != null;
    return Stack(
      children: [
        // The overlay only PAINTS over the child, which stays mounted — so
        // without these a screen reader could still traverse and read the
        // client names, addresses and phone numbers underneath a locked app,
        // and focus could still land in them.
        ExcludeSemantics(
          excluding: _locked,
          child: ExcludeFocus(excluding: _locked, child: widget.child),
        ),
        if (_locked)
          Positioned.fill(
            child: _LockOverlay(
              unavailable: _unavailable,
              pendingPhotoCount: _pendingPhotoCount,
              logOutError: _logOutError,
              isExiting: _exiting,
              onUnlock: _authenticate,
              onContinue: _release,
              onLogOut: canLogOut ? _logOut : null,
              onStayForPhotos: () => _onPhotoChoice(discard: false),
              onDiscardPhotos: () => _onPhotoChoice(discard: true),
            ),
          ),
      ],
    );
  }
}

class _LockOverlay extends StatelessWidget {
  const _LockOverlay({
    required this.unavailable,
    required this.pendingPhotoCount,
    required this.logOutError,
    required this.isExiting,
    required this.onUnlock,
    required this.onContinue,
    required this.onLogOut,
    required this.onStayForPhotos,
    required this.onDiscardPhotos,
  });

  final bool unavailable;
  final int? pendingPhotoCount;
  final String? logOutError;
  final bool isExiting;
  final Future<void> Function() onUnlock;
  final VoidCallback onContinue;
  final Future<void> Function()? onLogOut;
  final VoidCallback onStayForPhotos;
  final VoidCallback onDiscardPhotos;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.sp32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppRadius.r16),
                ),
                alignment: Alignment.center,
                child: FaIcon(
                  FontAwesomeIcons.lock,
                  size: 28,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: AppSpacing.sp16),
              if (pendingPhotoCount case final count?)
                ..._photoChoice(context, count)
              else
                ..._lockControls(context),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _lockControls(BuildContext context) {
    final l10n = context.l10n;
    return [
      _Headline(text: l10n.applock_title),
      if (unavailable) _Caption(text: l10n.settings_appLockUnavailable),
      if (logOutError case final error?) _Caption(text: error, isError: true),
      const SizedBox(height: AppSpacing.sp24),
      if (unavailable)
        FilledButton(onPressed: onContinue, child: Text(l10n.applock_continue))
      else
        FilledButton.icon(
          onPressed: onUnlock,
          icon: const Icon(Icons.lock_open_rounded, size: 18),
          label: Text(l10n.applock_unlock),
        ),
      if (onLogOut case final logOut?) ...[
        const SizedBox(height: AppSpacing.sp8),
        TextButton(
          onPressed: isExiting ? null : logOut,
          child: Text(l10n.applock_logOut),
        ),
      ],
    ];
  }

  List<Widget> _photoChoice(BuildContext context, int count) {
    final l10n = context.l10n;
    return [
      _Headline(text: l10n.auth_pendingPhotosTitle),
      _Caption(text: l10n.auth_pendingPhotosBody(count)),
      const SizedBox(height: AppSpacing.sp24),
      FilledButton(
        onPressed: onStayForPhotos,
        child: Text(l10n.auth_stayAndRetryPhotos),
      ),
      const SizedBox(height: AppSpacing.sp8),
      OutlinedButton(
        style: destructiveOutlinedButtonStyle(context),
        onPressed: onDiscardPhotos,
        child: Text(l10n.auth_discardPhotosAndContinue),
      ),
    ];
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.titleMedium,
    ),
  );
}

class _Caption extends StatelessWidget {
  const _Caption({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sp8),
      child: Semantics(
        liveRegion: true,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: isError ? scheme.error : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
