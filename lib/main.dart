import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:scheduling/core/adaptive/app_scroll_behavior.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/app/account_exit_listeners.dart';
import 'package:scheduling/core/app/analytics_identity_listener.dart';
import 'package:scheduling/core/app/app_sync_listeners.dart';
import 'package:scheduling/core/app/appointment_link_opener.dart';
import 'package:scheduling/core/app/carplay_bridge.dart';
import 'package:scheduling/core/connectivity/offline_banner.dart';
import 'package:scheduling/core/deep_links/deep_link_dispatcher.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/logging/unhandled_error_severity.dart';
import 'package:scheduling/core/navigation/top_route_observer.dart';
import 'package:scheduling/core/notices/notice_listener.dart';
import 'package:scheduling/core/notifications/fcm_background_handler.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/security/app_lock.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/core/utils/app_language.dart';
import 'package:scheduling/core/utils/debouncer.dart';
import 'package:scheduling/features/home_widget/application/widget_sync_service.dart';
import 'package:scheduling/features/live_activity/application/live_activity_registration_controller.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/onboarding/screens/onboarding_gate.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/settings/application/settings_providers.dart';
import 'package:scheduling/features/settings/data/shared_prefs_settings_repository.dart';
import 'package:scheduling/features/settings/domain/models/app_settings.dart';
import 'package:scheduling/firebase_options.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

const bool _useFirebaseEmulator = bool.fromEnvironment('USE_FIREBASE_EMULATOR');
// The iOS Simulator shares the host's network, so localhost is the right
// default.
const String _emulatorHost = String.fromEnvironment(
  'EMULATOR_HOST',
  defaultValue: '127.0.0.1',
);
const String _iosMapsApiKey = String.fromEnvironment('IOS_MAPS_API_KEY');
const MethodChannel _nativeConfigChannel = MethodChannel(
  'net.vogas.scheduling/native_config',
);

Future<void> _provideIosMapsApiKey() async {
  if (defaultTargetPlatform != TargetPlatform.iOS || _iosMapsApiKey.isEmpty) {
    return;
  }
  try {
    await _nativeConfigChannel.invokeMethod<void>(
      'provideGoogleMapsApiKey',
      _iosMapsApiKey,
    );
  } catch (error, stack) {
    // `debugPrint` is a no-op in release, so this failed silently in the only
    // build that matters: the channel handler returns early when the root view
    // controller is not a FlutterViewController yet, and the live map is then
    // permanently blank with nothing in Crashlytics.
    AppLogger().warn('MAPS-KEY provideGoogleMapsApiKey failed', error, stack);
  }
}

Future<void> _wireFirebaseEmulator() async {
  FirebaseFirestore.instance.useFirestoreEmulator(_emulatorHost, 8080);
  FirebaseFunctions.instance.useFunctionsEmulator(_emulatorHost, 5001);
  await Future.wait<void>([
    FirebaseAuth.instance.useAuthEmulator(_emulatorHost, 9099),
    FirebaseStorage.instance.useStorageEmulator(_emulatorHost, 9199),
  ]);
}

Future<void> _recordUnhandledError(
  Object error,
  StackTrace stack, {
  required bool fatal,
}) async {
  try {
    if (Firebase.apps.isEmpty) {
      debugPrint('Unhandled error before Firebase initialization: $error');
      debugPrintStack(stackTrace: stack);
      return;
    }
    await FirebaseCrashlytics.instance.recordError(error, stack, fatal: fatal);
  } catch (_) {
    debugPrint('Failed to report unhandled error: $error');
    debugPrintStack(stackTrace: stack);
  }
}

Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
      FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

      final settingsFuture = SharedPrefsSettingsRepository().load();

      await Future.wait([
        Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
        initializeDateFormatting('en_CA'),
        initializeDateFormatting('fr_CA'),
      ]);
      await _provideIosMapsApiKey();

      // Pin offline cache before first Firestore read (SplashScreen).
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
      );

      // iOS widget refresh on background push — must register before runApp.
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      Future<void> firebaseReady;
      if (_useFirebaseEmulator) {
        await _wireFirebaseEmulator();
        firebaseReady = Future<void>.value();
      } else {
        // Wire error handlers synchronously before activation futures.
        final crashlytics = FirebaseCrashlytics.instance;
        FlutterError.onError = crashlytics.recordFlutterFatalError;
        PlatformDispatcher.instance.onError = (error, stack) {
          unawaited(
            _recordUnhandledError(
              error,
              stack,
              fatal: isFatalUnhandledError(error),
            ),
          );
          return true;
        };

        // Not awaited — failures observed via firebaseReadyProvider.
        firebaseReady = Future.wait([
          crashlytics.setCrashlyticsCollectionEnabled(!kDebugMode),
          FirebaseAppCheck.instance.activate(
            providerAndroid: kDebugMode
                ? const AndroidDebugProvider()
                : const AndroidPlayIntegrityProvider(),
            providerApple: kDebugMode
                ? const AppleDebugProvider()
                : const AppleAppAttestProvider(),
          ),
        ]);
      }

      final settings = await settingsFuture;

      runApp(
        ProviderScope(
          retry: (retryCount, error) => null,
          overrides: [
            firebaseReadyProvider.overrideWith((ref) => firebaseReady),
          ],
          child: PaulApp(settings: settings),
        ),
      );
    },
    (error, stack) {
      unawaited(
        _recordUnhandledError(
          error,
          stack,
          fatal: isFatalUnhandledError(error),
        ),
      );
    },
  );
}

class PaulApp extends ConsumerStatefulWidget {
  const PaulApp({required this.settings, super.key});

  final AppSettings settings;

  @override
  ConsumerState<PaulApp> createState() => _PaulAppState();
}

class _PaulAppState extends ConsumerState<PaulApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final _settingsRepository = SharedPrefsSettingsRepository();
  late final Debouncer _settingsSaveDebouncer;
  final _topRouteObserver = TopRouteObserver();
  // Held so `dispose` can cancel them.
  late final AppointmentLinkOpener _linkOpener;
  late final CarPlayBridge _carPlayBridge;
  DeepLinkDispatcher? _deepLinkDispatcher;
  late ThemeMode _themeMode;
  late double _textScale;
  late AppLanguageController _languageController;
  bool _controllerSyncsPrimed = false;

  @override
  void initState() {
    super.initState();
    _settingsSaveDebouncer = Debouncer.tagged(
      kSettingsSaveDebounce,
      logger: ref.read(loggerProvider),
      tag: 'SETTINGS debounced save failed',
    );
    _themeMode = widget.settings.themeMode;
    _textScale = widget.settings.textScale;
    _languageController = AppLanguageController.instance;
    _languageController.setLanguage(widget.settings.language);
    _setupLinkOpening();
    _setupCarPlay();
    _setupDeepLinkHandling();
    _setupAnalytics();
  }

  /// Collection state and the two properties that never change mid-session.
  ///
  /// `user_role` is NOT set here — it follows the live account doc through
  /// [AnalyticsIdentityListener], because at this point nobody is signed in yet.
  void _setupAnalytics() {
    ref.read(analyticsServiceProvider)
      ..setCollectionEnabled(enabled: kAnalyticsCollectionEnabled)
      ..setBuildEnv(kAnalyticsBuildEnv)
      ..setAppLocale(widget.settings.language);
  }

  /// The two external entry points the `app_links` dispatcher doesn't own: iOS
  /// home-widget taps and notification taps.
  void _setupLinkOpening() {
    _linkOpener = AppointmentLinkOpener(
      ref: ref,
      navigatorKey: _navigatorKey,
      isMounted: () => mounted,
    )..start();
  }

  /// The CarPlay scene's Swift → Dart channel.
  void _setupCarPlay() {
    _carPlayBridge = ref.read(carPlayBridgeProvider)..start();
  }

  /// Inbound `esproschedule://` URLs — appointment links only since the invite
  /// code flow was retired.
  void _setupDeepLinkHandling() {
    _deepLinkDispatcher = DeepLinkDispatcher(
      logger: ref.read(loggerProvider),
      openAppointment: _linkOpener.openAppointment,
    )..start();
  }

  @override
  void dispose() {
    _linkOpener.dispose();
    _carPlayBridge.dispose();
    _deepLinkDispatcher?.dispose();
    _settingsSaveDebouncer.dispose();
    super.dispose();
  }

  void toggleTheme() {
    // Resolve the default `system` mode against the live OS brightness first,
    // then flip that — so one tap always changes the appearance, instead of
    // needing two taps on a dark phone.
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    setState(() {
      _themeMode = toggledThemeMode(_themeMode, platformBrightness);
    });
    ref
        .read(analyticsServiceProvider)
        .logSettingsChanged(
          settingName: AnalyticsSettings.theme,
          settingValue: _themeMode.name,
        );
    unawaited(_saveSettings(themeMode: _themeMode));
  }

  void setTextScale(double value) {
    setState(() {
      _textScale = value;
    });
    // Reported here rather than inside the debounced save: the debounce exists
    // to coalesce WRITES, and one event per settled write is what a drag along
    // the slider should produce.
    ref
        .read(analyticsServiceProvider)
        .logSettingsChanged(
          settingName: AnalyticsSettings.textScale,
          settingValue: value.toStringAsFixed(2),
        );
    _settingsSaveDebouncer.run(() => _saveSettings(textScale: value));
  }

  void setLanguage(String code) {
    _languageController.setLanguage(code);
    unawaited(_saveSettings(language: code));
    ref.read(analyticsServiceProvider)
      ..setAppLocale(code)
      ..logSettingsChanged(
        settingName: AnalyticsSettings.language,
        settingValue: code,
      );
    // Re-upsert the token so its `locale` field follows the app language.
    unawaited(ref.read(pushRegistrationControllerProvider).sync());
    // Same for the Live Activity tokens — `locale` drives the card's text.
    unawaited(ref.read(liveActivityRegistrationControllerProvider).sync());
    // The iOS home widget localizes its chrome/status labels from the payload's
    // `locale`.
    ref.invalidate(widgetPayloadProvider);
  }

  Future<void> _saveSettings({
    ThemeMode? themeMode,
    double? textScale,
    String? language,
  }) async {
    // Hoisted above the await for the same reason initState hoists one: this
    // runs from the debounce timer, which can fire after dispose, and
    // `ref.read` on an unmounted consumer throws.
    final logger = ref.read(loggerProvider);
    try {
      await _settingsRepository.save(
        themeMode: themeMode,
        textScale: textScale,
        language: language,
      );
    } catch (error, stackTrace) {
      logger.warn('SETTINGS save failed', error, stackTrace);
    }
  }

  /// Syncs once on first build, in case the account doc is already present —
  /// harmless if it's not ready yet.
  void _primeControllerSyncsOnce() {
    if (_controllerSyncsPrimed) return;
    _controllerSyncsPrimed = true;
    unawaited(ref.read(pushRegistrationControllerProvider).sync());
    unawaited(ref.read(presenceSyncControllerProvider).sync());
    unawaited(ref.read(liveActivityRegistrationControllerProvider).sync());
  }

  @override
  Widget build(BuildContext context) {
    AccountExitListeners(
      ref: ref,
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      isMounted: () => mounted,
    ).registerAll();
    // Register the sync listeners — the order here matters for
    // account-lifecycle control, so don't reorder these calls.
    AppSyncListeners(ref).registerAll();
    AnalyticsIdentityListener(ref).registerAll();
    _primeControllerSyncsOnce();
    return ThemeNotifier(
      themeMode: _themeMode,
      toggleTheme: toggleTheme,
      textScale: _textScale,
      setTextScale: setTextScale,
      setLanguage: setLanguage,
      child: ValueListenableBuilder<String>(
        valueListenable: _languageController,
        builder: (context, languageCode, _) {
          final locale = Locale(languageCode, 'CA');
          return MaterialApp(
            navigatorKey: _navigatorKey,
            navigatorObservers: [
              _topRouteObserver,
              ref.read(analyticsObserverProvider),
            ],
            scaffoldMessengerKey: _scaffoldMessengerKey,
            debugShowCheckedModeBanner: false,
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: lightTheme(),
            darkTheme: darkTheme(),
            // iOS "Increase Contrast". MaterialApp swaps to these itself when
            // MediaQuery.highContrastOf is true, so nothing branches at a call
            // site. docs/legal/accessibility.html claimed the app honoured this
            // setting while nothing in lib/ read the flag.
            highContrastTheme: highContrastLightTheme(),
            highContrastDarkTheme: highContrastDarkTheme(),
            themeMode: _themeMode,
            scrollBehavior: const AppScrollBehavior(),
            home: const OnboardingGate(),
            onGenerateRoute: AppRoutes.onGenerateRoute,
            builder: (context, child) {
              final media = MediaQuery.of(context);
              // Compose in-app text scale with the OS scale, capped app-wide.
              final systemFactor = media.textScaler.scale(14) / 14;
              final effectiveScale = math.min(
                _textScale * systemFactor,
                Breakpoints.maxTextScale,
              );
              // iOS "Bold Text". Flutter exposes the flag and applies it to
              // nothing, so the weight bump is ours to make — here, where the
              // RESOLVED theme is in scope, so it composes with light/dark and
              // with the high-contrast pair above.
              final theme = media.boldText
                  ? boldTextTheme(Theme.of(context))
                  : Theme.of(context);
              return MediaQuery(
                data: media.copyWith(
                  textScaler: TextScaler.linear(effectiveScale),
                ),
                child: Theme(
                  data: theme,
                  child: AppLock(
                    child: NoticeListener(
                      navigatorKey: _navigatorKey,
                      child: Column(
                        children: [
                          Expanded(child: child ?? const SizedBox.shrink()),
                          const OfflineBanner(),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
