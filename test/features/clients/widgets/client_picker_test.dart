import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_status.dart';
import 'package:scheduling/features/clients/domain/policies/phone_query_policy.dart';
import 'package:scheduling/features/clients/widgets/fields/client_picker.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/attached_dropdown.dart';

void main() {
  const marie = ClientRecord(
    id: 'c1',
    name: 'Marie Tremblay',
    phone: '5145628332',
  );
  const jp = ClientRecord(id: 'c2', name: 'J-P Gagnon', phone: '5145628901');

  Widget harness({
    required TextEditingController controller,
    List<ClientRecord> results = const [],
    ClientSearchStatus status = const ClientSearchStatus(),
    bool isSearching = false,
    ValueChanged<ClientRecord>? onSelect,
    VoidCallback? onRetry,
    VoidCallback? onAddNew,
    double textScale = 1,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: ClientPicker(
          controller: controller,
          results: results,
          status: status,
          isSearching: isSearching,
          onChanged: (_) {},
          onSelect: onSelect ?? (_) {},
          onRetry: onRetry ?? () {},
          onAddNew: onAddNew,
        ),
      ),
    ),
  );

  testWidgets('there is ONE bar and no mode switch', (tester) async {
    await tester.pumpWidget(harness(controller: TextEditingController()));
    expect(find.text('Search by name or phone'), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    expect(find.text('Phone'), findsNothing);
    expect(find.text('Name or address'), findsNothing);
  });

  testWidgets('a query carrying letters AND digits returns rows', (
    tester,
  ) async {
    // The formatter the mode switch installed discarded the letters, so this
    // query was untypeable without first finding the other segment.
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: 'marc 514'),
        results: [marie, jp],
        status: const ClientSearchStatus(mode: ClientQueryMode.text),
      ),
    );
    expect(find.text('Marie Tremblay'), findsOneWidget);
    expect(find.text('J-P Gagnon'), findsOneWidget);
  });

  testWidgets('holding shows the digit tally and no rows', (tester) async {
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: '(514) 5'),
        status: const ClientSearchStatus(digitsTyped: 4),
      ),
    );
    expect(find.text('4 of 10'), findsOneWidget);
    expect(find.text('Keep going'), findsOneWidget);
    expect(find.text('Attach'), findsNothing);
  });

  testWidgets('an empty query renders no results panel at all', (tester) async {
    await tester.pumpWidget(harness(controller: TextEditingController()));
    // Recent was removed 2026-09-06: search is the only way to a client.
    expect(find.text('Recent clients'), findsNothing);
    expect(find.text('Search results'), findsNothing);
  });

  testWidgets('an exact match renders one tappable result row', (tester) async {
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: '(514) 562-8332'),
        results: [marie],
        status: const ClientSearchStatus(
          digitsTyped: 10,
          answeredRung: PhoneRung.canonical,
        ),
      ),
    );
    // The "Attach" verb was dropped 2026-09-12 (owner call) — the row itself
    // is the whole control, so the match is what proves it rendered. The
    // formatted number is NOT the assertion: the field's own text carries it
    // too, so it matches twice and says nothing about the row.
    expect(find.byType(AttachedDropdownRow), findsOneWidget);
    expect(find.text('Marie Tremblay'), findsOneWidget);
  });

  testWidgets('tapping the row attaches, and nothing attaches on its own', (
    tester,
  ) async {
    ClientRecord? attached;
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: '(514) 562-8332'),
        results: [marie],
        status: const ClientSearchStatus(
          digitsTyped: 10,
          answeredRung: PhoneRung.canonical,
        ),
        onSelect: (c) => attached = c,
      ),
    );
    expect(attached, isNull, reason: 'never auto-attach');
    await tester.tap(find.text('Marie Tremblay'));
    await tester.pump();
    expect(attached, marie);
  });

  testWidgets('several text results are never captioned as near misses', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: 'mar'),
        results: [marie, jp],
        status: const ClientSearchStatus(
          mode: ClientQueryMode.text,
          answeredRung: PhoneRung.canonical,
        ),
      ),
    );
    expect(find.text('NO EXACT MATCH · CLOSEST NUMBERS'), findsNothing);
    expect(find.text('Marie Tremblay'), findsOneWidget);
    expect(find.text('J-P Gagnon'), findsOneWidget);
  });

  testWidgets('a text search leads with the name, the number beneath', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: 'marie'),
        results: [marie],
        status: const ClientSearchStatus(
          mode: ClientQueryMode.text,
          answeredRung: PhoneRung.canonical,
        ),
      ),
    );
    expect(find.text('NO EXACT MATCH · CLOSEST NUMBERS'), findsNothing);
    expect(find.text('Marie Tremblay'), findsOneWidget);
    expect(find.text('(514) 562-8332'), findsOneWidget);
  });

  testWidgets('a fallback answer is captioned as closest, not as matches', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: '(514) 562-8233'),
        results: [marie, jp],
        status: const ClientSearchStatus(
          digitsTyped: 10,
          answeredRung: PhoneRung.firstSeven,
        ),
        onAddNew: () {},
      ),
    );
    expect(find.text('NO EXACT MATCH · CLOSEST NUMBERS'), findsOneWidget);
    expect(find.text('None of these — new client'), findsOneWidget);
  });

  testWidgets('results render as an attached dropdown, not a titled panel', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: '(514) 562-8332'),
        results: [marie],
        status: const ClientSearchStatus(
          digitsTyped: 10,
          answeredRung: PhoneRung.canonical,
        ),
      ),
    );
    // The panel header and match count are gone with Option A.
    expect(find.text('Exact match'), findsNothing);
    expect(find.text('1 match'), findsNothing);
    expect(find.textContaining('Marie Tremblay'), findsOneWidget);
  });

  testWidgets('an exact hit carries NO caption', (tester) async {
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: '(514) 562-8332'),
        results: [marie],
        status: const ClientSearchStatus(
          digitsTyped: 10,
          answeredRung: PhoneRung.canonical,
        ),
      ),
    );
    expect(find.text('NO EXACT MATCH · CLOSEST NUMBERS'), findsNothing);
  });

  testWidgets('searching shows a suffix spinner and KEEPS the results', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: 'lemi'),
        results: [marie],
        status: const ClientSearchStatus(mode: ClientQueryMode.text),
        isSearching: true,
      ),
    );
    // The old build replaced the whole body with a centred indicator, so the
    // list jumped on every keystroke.
    expect(find.textContaining('Marie Tremblay'), findsOneWidget);
    expect(find.byType(AdaptiveProgressIndicator), findsOneWidget);
  });

  testWidgets('a failed search is not an empty one', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: '(514) 562-8332'),
        status: const ClientSearchStatus(digitsTyped: 10, failed: true),
        onRetry: () => retried = true,
      ),
    );
    expect(find.text("Couldn't check that number"), findsOneWidget);
    expect(find.text('No clients found'), findsNothing);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });

  testWidgets('add-new is absent when the host offers no callback', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: '(514) 562-8233'),
        status: const ClientSearchStatus(digitsTyped: 10),
      ),
    );
    expect(find.textContaining('new client'), findsNothing);
  });

  testWidgets('no overflow on a small phone at 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: '(514) 562-8332'),
        results: [marie, jp],
        status: const ClientSearchStatus(
          digitsTyped: 10,
          answeredRung: PhoneRung.canonical,
        ),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dropdown survives a 260px phone at 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      harness(
        controller: TextEditingController(text: '(514) 562-8999'),
        results: [marie, jp],
        status: const ClientSearchStatus(
          digitsTyped: 10,
          answeredRung: PhoneRung.firstSeven,
        ),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
