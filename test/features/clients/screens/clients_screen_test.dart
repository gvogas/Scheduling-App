import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/features/clients/screens/clients_screen.dart';
import 'package:scheduling/features/clients/widgets/sheets/clients_filter_sheet.dart';
import 'package:scheduling/features/clients/widgets/sheets/edit_client_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClientsRepo extends Mock implements ClientsRepository {}

const _alice = ClientRecord(
  id: 'c1',
  name: 'Alice Brown',
  phone: '555-0101',
  address: '1 Main St',
  email: 'alice@example.com',
);

const _bob = ClientRecord(
  id: 'c2',
  name: 'Bob Carter',
  phone: '555-0202',
  address: '2 Main St',
  email: 'bob@example.com',
);

Widget _wrap(ClientsRepository repo) {
  return ProviderScope(
    overrides: [clientsRepositoryProvider.overrideWithValue(repo)],
    child: ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: 1,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        home: const ListInformation(isAdmin: true, employeeId: 'admin'),
      ),
    ),
  );
}

/// The edit sheet's own Save verb, scoped so the detail's "Save to contacts"
/// tile behind the sheet can't match it.
Finder _sheetSave() => find.descendant(
  of: find.byType(EditClientSheet),
  matching: find.widgetWithText(TextButton, 'Save'),
);

Finder _phoneEditField() => find.descendant(
  of: find.byWidgetPredicate(
    (w) => w is LabeledTextField && w.label == 'Phone',
  ),
  matching: find.byType(TextField),
);

void main() {
  late _MockClientsRepo repo;

  setUpAll(() {
    registerFallbackValue(const ClientRecord(id: ''));
    registerFallbackValue(ClientsSort.name);
    registerFallbackValue(ClientType.unset);
  });

  setUp(() {
    repo = _MockClientsRepo();
  });

  testWidgets('renders the first page of client names', (tester) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => const [_alice, _bob]);

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.textContaining('Alice'), findsWidgets);
    expect(find.textContaining('Bob'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows empty-state copy when the page is empty', (tester) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => const []);

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    // Exact, not textContaining: the list header legitimately renders its own
    // "No clients" count beside the empty state's "No clients yet".
    expect(find.text('No clients yet'), findsOneWidget);
    expect(find.text('No clients'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows fallback copy when the first page errors', (tester) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
      ),
    ).thenThrow(Exception('boom'));

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't load clients"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first-page error offers a Retry that reloads the list', (
    tester,
  ) async {
    var calls = 0;
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async {
      if (calls++ == 0) throw Exception('boom');
      return const [_alice];
    });

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't load clients"), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Alice'), findsWidgets);
    expect(find.textContaining("Couldn't load clients"), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('split-layout detail pane keeps showing an in-pane edit after the '
      'post-save list refresh (no stale snapshot)', (tester) async {
    // Wide viewport so the master-detail split renders its detail pane;
    // tall so every edit field is laid out.
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The edit-save flow consults the contact-link store (SharedPreferences);
    // with no link present the phone-contact sync is a no-op.
    SharedPreferences.setMockInitialValues({});

    // The list still serves the pre-edit record after the save-driven refresh —
    // the detail pane must keep showing the edit, not re-seed from the stale snapshot.
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => const [_alice]);
    when(() => repo.updateClient(any())).thenAnswer((_) async {});

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    // Select Alice into the split-layout detail pane, then edit her phone.
    await tester.tap(find.text('Alice Brown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(_phoneEditField().first, '5145559999');
    // Let SheetFocusScroll's 280 ms focus-scroll timer fire.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(_sheetSave());
    await tester.pumpAndSettle();

    // Back in view mode with the new phone — not the stale '555-0101'.
    expect(find.byType(EditClientSheet), findsNothing);
    expect(find.text('(514) 555-9999'), findsWidgets);
    final saved =
        verify(() => repo.updateClient(captureAny())).captured.single
            as ClientRecord;
    expect(saved.phone, '(514) 555-9999');
    expect(tester.takeException(), isNull);
  });

  // The per-type chips were removed 2026-09-11 (owner call): the sheet the
  // button opens already offers every one of them.
  testWidgets('offers the Filter button alone, with no type chips', (
    tester,
  ) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((_) async => const []);

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.text('Residential'), findsNothing);
    expect(find.text('Commercial'), findsNothing);
  });

  testWidgets('the search hint names every matched field', (tester) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((_) async => const []);

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Name, phone, address, email…'), findsOneWidget);
  });

  testWidgets('picking a type in the sheet narrows the list to it', (
    tester,
  ) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((_) async => const []);
    when(
      () => repo.fetchClientsPage(
        limit: any(named: 'limit'),
        after: any(named: 'after'),
        sort: any(named: 'sort'),
        filter: const ClientsFilterType(ClientType.residential),
      ),
    ).thenAnswer(
      (_) async => const [
        ClientRecord(id: 'r1', name: 'Rita Home', type: ClientType.residential),
      ],
    );

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    // The sheet's own option, scoped past the chip of the same name behind it.
    await tester.tap(find.text('Residential').last);
    await tester.pumpAndSettle();

    expect(find.text('Rita Home'), findsOneWidget);
  });

  // With the chips gone the sheet is the only way in, so it is what the
  // button has to reach.
  testWidgets('the Filter button opens the filter sheet', (tester) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((_) async => const []);
    when(repo.fetchBuildings).thenAnswer((_) async => const []);

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    expect(find.byType(ClientsFilterSheet), findsOneWidget);
  });
}
