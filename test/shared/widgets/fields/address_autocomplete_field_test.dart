import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/core/utils/debouncer.dart';
import 'package:scheduling/features/maps/application/maps_providers.dart';
import 'package:scheduling/features/maps/domain/maps_failure.dart';
import 'package:scheduling/features/maps/domain/models/address_suggestion.dart';
import 'package:scheduling/features/maps/domain/models/parsed_address.dart';
import 'package:scheduling/features/maps/domain/places_repository.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/address_autocomplete_field.dart';

/// 307 lines and no test file at all, on the most-typed-into field in the app.
///
/// Three of the four things left unexercised are guards against BILLED Google
/// Places calls — the `_lastFetched` dedupe, the `_requestId` stale-response
/// discard and the session-token lifecycle (Places bills an autocomplete
/// session as one unit only while its token is reused, so a token that never
/// rotates, or rotates per keystroke, changes the bill). The fourth is the
/// post-dispose path that already shipped a FATAL once.
///
/// NOTE: never `pumpAndSettle` here. The field renders a progress indicator
/// while a lookup is in flight, so settling times out instead of failing.
class _RecordingPlaces implements PlacesRepository {
  List<AddressSuggestion> suggestions = const [];
  ParsedAddress? details;

  /// Session tokens seen, in call order — one per autocomplete AND per detail.
  final tokens = <String>[];
  final queries = <String>[];

  /// When set, the next autocomplete waits on this instead of returning.
  Completer<List<AddressSuggestion>>? gate;
  Object? throws;
  Exception? detailsThrows;

  @override
  Future<List<AddressSuggestion>> autocomplete(
    String input, {
    required String sessionToken,
  }) {
    queries.add(input);
    tokens.add(sessionToken);
    final pending = gate;
    if (pending != null) {
      gate = null;
      return pending.future;
    }
    if (throws != null) return Future<List<AddressSuggestion>>.error(throws!);
    return Future.value(suggestions);
  }

  @override
  Future<ParsedAddress> getPlaceDetails(
    String placeId, {
    required String sessionToken,
  }) async {
    tokens.add(sessionToken);
    if (detailsThrows != null) throw detailsThrows!;
    return details ?? const ParsedAddress();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records every log line, so a test can count logs per failure.
class _RecordingLogger extends AppLogger {
  final lines = <String>[];

  @override
  void warn(String message, [Object? error, StackTrace? stack]) =>
      lines.add(message);

  @override
  void breadcrumb(String message) => lines.add(message);
}

void main() {
  late TextEditingController controller;
  late _RecordingPlaces places;
  late List<String> reported;
  late _RecordingLogger logger;

  setUp(() {
    controller = TextEditingController();
    places = _RecordingPlaces();
    reported = [];
    logger = _RecordingLogger();
  });

  tearDown(() => controller.dispose());

  Widget app({required bool showField}) => ProviderScope(
    overrides: [
      placesRepositoryProvider.overrideWithValue(places),
      loggerProvider.overrideWithValue(logger),
    ],
    child: MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      home: Scaffold(
        body: showField
            ? AddressAutocompleteField(
                controller: controller,
                onChanged: reported.add,
              )
            : const SizedBox.shrink(),
      ),
    ),
  );

  Future<void> pumpField(WidgetTester tester, {bool showField = true}) async {
    await tester.pumpWidget(app(showField: showField));
    await tester.pump();
  }

  /// Types [text] without letting the debounce fire.
  Future<void> typeOnly(WidgetTester tester, String text) =>
      tester.enterText(find.byType(TextField), text);

  /// Lets the debounce fire and any settled future deliver.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(kAddressLookupDebounce + const Duration(milliseconds: 1));
    await tester.pump();
    await tester.pump();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await typeOnly(tester, text);
    await settle(tester);
  }

  testWidgets('a query below the minimum length never reaches Places', (
    tester,
  ) async {
    // Every request is billed, so the short-query guard is a cost control, not
    // a UX nicety.
    await pumpField(tester);
    await type(tester, '12');

    expect(places.queries, isEmpty);
  });

  testWidgets('a keystroke undone inside the debounce is not re-fetched', (
    tester,
  ) async {
    // `_lastFetched`. Typing a character and deleting it before the debounce
    // fires leaves the field back on text it already has results for — the
    // guard is what stops that costing a second billed call.
    places.suggestions = const [
      AddressSuggestion(placeId: 'p1', description: '1 Main St, Montreal'),
    ];
    await pumpField(tester);
    await type(tester, '1 Main St');
    expect(places.queries, ['1 Main St']);

    await typeOnly(tester, '1 Main Stx');
    await typeOnly(tester, '1 Main St');
    await settle(tester);

    expect(places.queries, ['1 Main St'], reason: 'no second billed call');
  });

  testWidgets('a FAILED query is retried, unlike a settled one', (
    tester,
  ) async {
    // The other half of the dedupe: `_lastFetched` is set on success only, or
    // a transient failure would leave the field permanently unable to look up
    // that address.
    places.throws = Exception('network');
    await pumpField(tester);
    await type(tester, '1 Main St');
    expect(places.queries, ['1 Main St']);

    await typeOnly(tester, '1 Main Stx');
    await typeOnly(tester, '1 Main St');
    await settle(tester);

    expect(places.queries, ['1 Main St', '1 Main St']);
  });

  testWidgets('a stale response is discarded rather than shown', (
    tester,
  ) async {
    // `_requestId`. Two lookups in flight and the SLOWER one landing last
    // would otherwise replace the newer query's suggestions with the older
    // query's — the classic autocomplete race.
    final slow = Completer<List<AddressSuggestion>>();
    places
      ..gate = slow
      ..suggestions = const [
        AddressSuggestion(placeId: 'p2', description: 'FRESH RESULT'),
      ];

    await pumpField(tester);
    await type(tester, 'old query');
    await type(tester, 'new query');
    expect(find.text('FRESH RESULT'), findsOneWidget);

    // The first request answers last, with results for text nobody has now.
    slow.complete(const [
      AddressSuggestion(placeId: 'p1', description: 'STALE RESULT'),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text('STALE RESULT'), findsNothing);
    expect(find.text('FRESH RESULT'), findsOneWidget);
  });

  testWidgets('one session token spans the whole autocomplete session', (
    tester,
  ) async {
    // Places bills an autocomplete session as ONE unit only while its token is
    // reused across the keystrokes and the final details call. A token minted
    // per request bills per keystroke instead.
    places
      ..suggestions = const [
        AddressSuggestion(placeId: 'p1', description: '1 Main St, Montreal'),
      ]
      ..details = const ParsedAddress(fullAddress: '1 Main St, Montreal, QC');

    await pumpField(tester);
    await type(tester, '1 Mai');
    await type(tester, '1 Main');
    await tester.tap(find.text('1 Main St, Montreal'));
    await settle(tester);

    expect(places.tokens, hasLength(3));
    expect(places.tokens.toSet(), hasLength(1), reason: 'one billed session');
  });

  testWidgets('a NEW session gets a new token once the last one closed', (
    tester,
  ) async {
    // The token is cleared at the end of `_selectSuggestion`, so the next
    // address the user looks up starts a fresh billable session rather than
    // riding an expired one.
    places
      ..suggestions = const [
        AddressSuggestion(placeId: 'p1', description: '1 Main St, Montreal'),
      ]
      ..details = const ParsedAddress(fullAddress: '1 Main St, Montreal, QC');

    await pumpField(tester);
    await type(tester, '1 Main');
    await tester.tap(find.text('1 Main St, Montreal'));
    await settle(tester);
    final firstSession = places.tokens.last;

    places.suggestions = const [
      AddressSuggestion(placeId: 'p9', description: '9 Oak Ave, Laval'),
    ];
    // TWO keystrokes, deliberately. `controller.text = ` notifies listeners
    // but does NOT fire a TextField's `onChanged`, so the two
    // `_suppressFetch = true` assignments in `_selectSuggestion` are never
    // consumed by the programmatic writes they guard — the first real
    // keystroke after a selection absorbs one instead. Harmless (the flag is a
    // bool, so exactly one is swallowed) but it is what the field does.
    await type(tester, '9 Oak');
    await type(tester, '9 Oak Ave');

    expect(places.tokens.last, isNot(firstSession));
  });

  testWidgets('a lookup that fails AFTER dispose does not escape as a crash', (
    tester,
  ) async {
    // The known-FATAL path. `_fetch` runs from a Debouncer timer with no
    // caller left to catch it, so a `ref.read` below the await threw a
    // StateError straight into the zone handler — every time an address lookup
    // failed after its sheet was dismissed.
    final gate = Completer<List<AddressSuggestion>>();
    places.gate = gate;

    await pumpField(tester);
    await type(tester, '1 Main St');

    // The sheet closes while Places is still thinking.
    await pumpField(tester, showField: false);
    gate.completeError(Exception('network'));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('the clear button drops the suggestions and tells the host', (
    tester,
  ) async {
    // A programmatic `controller.clear()` never fires the field's own
    // onChanged, so without the explicit call the host keeps an address the
    // user can no longer see.
    places.suggestions = const [
      AddressSuggestion(placeId: 'p1', description: '1 Main St, Montreal'),
    ];

    await pumpField(tester);
    await type(tester, '1 Main St');
    expect(find.text('1 Main St, Montreal'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.clear));
    await settle(tester);

    expect(reported.last, '');
    expect(find.text('1 Main St, Montreal'), findsNothing);
  });

  testWidgets('a server-side pause shows the paused message, not an error', (
    tester,
  ) async {
    // A server-only pause can outlive the client flag; a silent field looks
    // broken while every keystroke is refused again.
    places.throws = const MapsFailurePaused();
    await pumpField(tester);
    await type(tester, '1 Main St');

    expect(places.queries, ['1 Main St']);
    final l10n = AppLocalizations.of(tester.element(find.byType(TextField)));
    expect(find.text(l10n.common_featurePaused), findsOneWidget);
    expect(find.text(l10n.error_addressLookupFailed), findsNothing);
    expect(find.byType(AdaptiveProgressIndicator), findsNothing);
    // The repository already breadcrumbed it; the field adds nothing.
    expect(logger.lines, isEmpty);
  });

  testWidgets('a server-side pause on details keeps the typed address', (
    tester,
  ) async {
    final selected = <String>[];
    places
      ..suggestions = const [
        AddressSuggestion(placeId: 'p1', description: '1 Main St, Montreal'),
      ]
      ..detailsThrows = const MapsFailurePaused();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [placesRepositoryProvider.overrideWithValue(places)],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          home: Scaffold(
            body: AddressAutocompleteField(
              controller: controller,
              onAddressSelected: selected.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await type(tester, '1 Main');
    await tester.tap(find.text('1 Main St, Montreal'));
    await settle(tester);

    expect(controller.text, '1 Main St, Montreal');
    expect(selected, ['1 Main St, Montreal']);
    final l10n = AppLocalizations.of(tester.element(find.byType(TextField)));
    expect(find.text(l10n.common_featurePaused), findsNothing);
    expect(find.text(l10n.error_couldNotLoadAddressDetails), findsNothing);
  });

  testWidgets('only an untyped error is logged by the field itself', (
    tester,
  ) async {
    places.throws = const MapsFailureRateLimit();
    await pumpField(tester);
    await type(tester, '1 Main St');
    expect(logger.lines, isEmpty);

    places.throws = StateError('boom');
    await type(tester, '2 Main St');
    expect(logger.lines, ['ADDR-AUTO autocomplete failed']);
  });

  group('suggestion rows', () {
    const split = AddressSuggestion(
      placeId: 'p1',
      description: '1 Main St, Montreal, QC, Canada',
      mainText: '1 Main St',
      secondaryText: 'Montreal, QC, Canada',
    );

    Future<void> showSuggestions(
      WidgetTester tester,
      List<AddressSuggestion> suggestions, {
      double textScale = 1,
    }) async {
      places.suggestions = suggestions;
      await tester.pumpWidget(
        _harness(places: places, controller: controller, textScale: textScale),
      );
      await tester.pump();
      await type(tester, '1 Main');
    }

    testWidgets('renders a bold street line over a muted city line', (
      tester,
    ) async {
      await showSuggestions(tester, const [split]);

      final theme = Theme.of(tester.element(find.byType(TextField)));
      final street = tester.widget<Text>(find.text('1 Main St'));
      final city = tester.widget<Text>(find.text('Montreal, QC, Canada'));
      expect(
        (street.style?.fontWeight, city.style?.color, street.maxLines),
        (FontWeight.w600, theme.palette.textTertiary, 1),
      );
    });

    testWidgets('falls back to the flat description without a street line', (
      tester,
    ) async {
      await showSuggestions(tester, const [
        AddressSuggestion(placeId: 'p1', description: '1 Main St, Montreal'),
      ]);

      final row = tester.widget<Text>(find.text('1 Main St, Montreal'));
      expect(row.maxLines, 2);
    });

    testWidgets('the split row still reads the full address', (tester) async {
      final handle = tester.ensureSemantics();
      await showSuggestions(tester, const [split]);

      expect(
        find.bySemanticsLabel('1 Main St, Montreal, QC, Canada'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('does not overflow at 260 px with 2x text', (tester) async {
      tester.view
        ..physicalSize = const Size(260, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await showSuggestions(tester, const [
        AddressSuggestion(
          placeId: 'p1',
          description: '12345 Boulevard Saint-Laurent, Montreal, QC, Canada',
          mainText: '12345 Boulevard Saint-Laurent',
          secondaryText: 'Montreal, QC H2X 2V1, Canada',
        ),
        AddressSuggestion(
          placeId: 'p2',
          description: '9876 Rue Sainte-Catherine Ouest, Montreal, QC',
        ),
      ], textScale: 2);

      expect(find.text('12345 Boulevard Saint-Laurent'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

Widget _harness({
  required PlacesRepository places,
  required TextEditingController controller,
  double textScale = 1,
}) {
  return ProviderScope(
    overrides: [placesRepositoryProvider.overrideWithValue(places)],
    child: MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AddressAutocompleteField(controller: controller),
        ),
      ),
    ),
  );
}
