import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/security/biometric_auth_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/settings/application/app_lock_provider.dart';
import 'package:scheduling/l10n/l10n.dart';

/// App-wide biometric gate. Covers the app on cold start, and again whenever
/// it returns from the background.
class AppLock extends ConsumerStatefulWidget {
  const AppLock({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppLock> createState() => _AppLockState();
}

class _AppLockState extends ConsumerState<AppLock> with WidgetsBindingObserver {
  bool _locked = false;
  bool _authenticating = false;

  /// True when [_locked] was taken because the flag was UNRESOLVED rather than
  /// because it is on. Resume clears such a lock once the retry settles, so a
  /// user who never opted in can't be trapped behind a biometric prompt they
  /// may have no way to satisfy.
  bool _lockedUnresolved = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lockOnStartIfEnabled();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      if (_lockedUnresolved) {
        setState(() {
          _locked = false;
          _lockedUnresolved = false;
        });
      }
      return;
    }
    _lockedUnresolved = false;
    if (_locked) {
      unawaited(_authenticate());
    } else {
      _lockIfEnabled();
    }
  }

  Future<void> _authenticate() async {
    if (_authenticating || !mounted) return;
    _authenticating = true;
    // Riverpod 3 throws on `ref.read` from an unmounted consumer, so every
    // provider this path needs is resolved before the first await.
    final logger = ref.read(loggerProvider);
    final notices = ref.read(noticeServiceProvider);
    final service = ref.read(biometricAuthServiceProvider);
    try {
      final available = await service.isAvailable();
      if (!mounted) return;
      if (!available) {
        // Session-only release, never persisted: `isAvailable()` is false in the pre-first-unlock window.
        logger.warn(
          'APPLOCK unavailable after lock engaged; opening for this session',
        );
        notices.error(context.l10n.settings_appLockUnavailable);
        setState(() {
          _locked = false;
          _lockedUnresolved = false;
        });
        return;
      }

      final reason = context.l10n.applock_reason;
      final ok = await service.authenticate(reason);
      if (ok && mounted) {
        setState(() {
          _locked = false;
          _lockedUnresolved = false;
        });
      }
    } catch (e, st) {
      logger.warn('APPLOCK authenticate flow failed', e, st);
    } finally {
      _authenticating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
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
          Positioned.fill(child: _LockOverlay(onUnlock: _authenticate)),
      ],
    );
  }
}

class _LockOverlay extends StatelessWidget {
  const _LockOverlay({required this.onUnlock});

  final Future<void> Function() onUnlock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: Padding(
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
              Text(
                context.l10n.applock_title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sp24),
              FilledButton.icon(
                onPressed: onUnlock,
                icon: const Icon(Icons.lock_open_rounded, size: 18),
                label: Text(context.l10n.applock_unlock),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
