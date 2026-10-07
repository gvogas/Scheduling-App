import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart' show NavigatorObserver;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/analytics/analytics_service.dart';
import 'package:scheduling/core/logging/app_logger.dart';

/// Opt-in switch that turns collection ON in a debug build, for DebugView work.
///
/// Pass `--dart-define=ANALYTICS_DEBUG=true`. It is a compile-time const, so a
/// release build cannot be flipped into debug reporting by anything at runtime.
const bool kAnalyticsDebug = bool.fromEnvironment('ANALYTICS_DEBUG');

/// Whether this build reports at all.
///
/// Debug builds are OFF by default. Every `flutter run` otherwise files real
/// events against the production property, and the noise is indistinguishable
/// from real usage precisely because it comes from a real device doing
/// real-looking things — the same reason `main()` disables Crashlytics
/// collection in debug.
const bool kAnalyticsCollectionEnabled = !kDebugMode || kAnalyticsDebug;

/// `release` / `debug`, so DebugView traffic stays filterable in the console.
const String kAnalyticsBuildEnv = kDebugMode
    ? AnalyticsBuildEnvs.debug
    : AnalyticsBuildEnvs.release;

final analyticsServiceProvider = Provider<AnalyticsService>(
  (ref) => AnalyticsService(logger: ref.read(loggerProvider)),
);

/// The official navigation observer, wired to this app's screen-name mapping.
///
/// [analyticsScreenForRoute] returns null for a route the observer must skip —
/// an unnamed modal sheet, or one of the four hub-tab routes the shell reports
/// itself — and a null `nameExtractor` result makes the observer ignore that
/// push entirely.
final analyticsObserverProvider = Provider<NavigatorObserver>((ref) {
  final analytics = ref.watch(analyticsServiceProvider);
  final logger = ref.read(loggerProvider);
  return analytics.navigationObserver(
    nameExtractor: (settings) => analyticsScreenForRoute(settings.name),
    onError: (error) => logger.warn('ANALYTICS route observer failed', error),
  );
});
