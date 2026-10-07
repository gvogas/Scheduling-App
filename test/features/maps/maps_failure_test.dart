import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/maps/domain/maps_failure.dart';
import 'package:scheduling/l10n/l10n.dart';

/// E3: typed `MapsFailure` family must hold its raw cause for logs but
/// must NOT expose response-body / API noise via `toLocalizedMessage`.
void main() {
  Future<BuildContext> harness(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      Localizations(
        locale: const Locale('en'),
        delegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        child: Builder(
          builder: (ctx) {
            captured = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return captured;
  }

  testWidgets('MapsFailureNetwork resolves to addressLookupFailed', (
    tester,
  ) async {
    final context = await harness(tester);
    const failure = MapsFailureNetwork(cause: 'autocomplete HTTP 500');
    expect(
      failure.toLocalizedMessage(context),
      AppLocalizations.of(context).error_addressLookupFailed,
    );
  });

  testWidgets('MapsFailureParse resolves to couldNotLoadAddressDetails', (
    tester,
  ) async {
    final context = await harness(tester);
    const failure = MapsFailureParse();
    expect(
      failure.toLocalizedMessage(context),
      AppLocalizations.of(context).error_couldNotLoadAddressDetails,
    );
  });

  testWidgets('MapsFailureRateLimit resolves to tooManyAttempts copy', (
    tester,
  ) async {
    final context = await harness(tester);
    const failure = MapsFailureRateLimit();
    expect(
      failure.toLocalizedMessage(context),
      AppLocalizations.of(context).error_tooManyAttemptsPleaseTryAgainLater,
    );
  });

  testWidgets('MapsFailureUnauthorized resolves to retry copy', (tester) async {
    final context = await harness(tester);
    const failure = MapsFailureUnauthorized();
    expect(
      failure.toLocalizedMessage(context),
      AppLocalizations.of(context).error_somethingWentWrongPleaseTryAgain,
    );
  });

  testWidgets('MapsFailureInvalidInput resolves to generic copy', (
    tester,
  ) async {
    final context = await harness(tester);
    const failure = MapsFailureInvalidInput();
    expect(
      failure.toLocalizedMessage(context),
      AppLocalizations.of(context).error_somethingWentWrong,
    );
  });

  testWidgets('MapsFailurePaused resolves to the feature-paused copy', (
    tester,
  ) async {
    final context = await harness(tester);
    const failure = MapsFailurePaused();
    expect(
      failure.toLocalizedMessage(context),
      AppLocalizations.of(context).common_featurePaused,
    );
  });

  testWidgets('localized message never leaks the raw cause string', (
    tester,
  ) async {
    final context = await harness(tester);
    // Guards against the original bug where `throw Exception('Autocomplete failed: ${response.body}')` could surface API payloads to users/logs.
    const sentinel = '!!SENSITIVE_RESPONSE_BODY!!';
    const failures = <MapsFailure>[
      MapsFailureNetwork(cause: sentinel),
      MapsFailureParse(cause: sentinel),
      MapsFailureRateLimit(cause: sentinel),
      MapsFailureUnauthorized(cause: sentinel),
      MapsFailureInvalidInput(cause: sentinel),
      MapsFailurePaused(cause: sentinel),
    ];
    for (final f in failures) {
      expect(
        f.toLocalizedMessage(context),
        isNot(contains(sentinel)),
        reason: f.runtimeType.toString(),
      );
    }
  });
}
