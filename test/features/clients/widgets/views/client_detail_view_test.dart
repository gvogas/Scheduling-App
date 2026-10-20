import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/application/appointment_history_providers.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/widgets/sheets/edit_client_sheet.dart';
import 'package:scheduling/features/clients/widgets/views/client_detail_view.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClientsRepo extends Mock implements ClientsRepository {}

const _personClient = ClientRecord(
  id: 'c1',
  name: 'Carol Smith',
  phone: '555-0303',
  address: '2 Main St',
);

const _clientWithContacts = ClientRecord(
  id: 'c2',
  name: 'Acme Corp',
  phone: '555-0101',
  address: '1 Main St',
  contacts: [ClientContact(name: 'Bob Builder', phone: '555-0202')],
);

Widget _wrap(ClientsRepository repo, ClientRecord client) {
  return ProviderScope(
    overrides: [
      clientsRepositoryProvider.overrideWithValue(repo),
      // The Job History section reads the real appointments repo; serve an
      // empty history so this contacts-only test doesn't hit Firebase.
      clientJobHistoryProvider.overrideWith(
        (ref, clientId) async => <AppointmentRecord>[],
      ),
    ],
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
        home: Scaffold(body: ClientDetailView(client: client)),
      ),
    ),
  );
}

/// The edit sheet's own Save verb. Scoped, because the read-only detail behind
/// the sheet carries a "Save to contacts" tile whose label also renders "Save".
Finder _sheetSave() => find.descendant(
  of: find.byType(EditClientSheet),
  matching: find.widgetWithText(TextButton, 'Save'),
);

Finder _textFieldFor(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is LabeledTextField && w.label == label),
  matching: find.byType(TextField),
);

/// Pumps the detail view at a tall viewport (so every edit field is built)
/// and opens the edit sheet above it.
Future<void> _pumpInEditMode(
  WidgetTester tester,
  ClientsRepository repo,
  ClientRecord client,
) async {
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_wrap(repo, client));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
}

void main() {
  late _MockClientsRepo repo;

  setUpAll(() {
    registerFallbackValue(const ClientRecord(id: ''));
  });

  setUp(() {
    // With no contact-link present, the edit-save phone-contact sync is a no-op.
    SharedPreferences.setMockInitialValues({});
    repo = _MockClientsRepo();
    // Default: the live doc read yields nothing, so every test below exercises
    // the fallback — the record the view was handed, plus its own optimistic
    // updates. The live path has its own test.
    when(
      () => repo.watchClient(any()),
    ).thenAnswer((_) => const Stream<ClientRecord?>.empty());
  });

  testWidgets('the Wave sync badge follows the live doc, not the record the '
      'view was handed', (tester) async {
    final live = StreamController<ClientRecord?>();
    addTearDown(live.close);
    when(() => repo.watchClient('c1')).thenAnswer((_) => live.stream);

    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // "synced" is exactly what an edit leaves behind in the record the sheet
    // pops back: the waveUpsertCustomer trigger stamps `pending` only after the
    // save has already returned, so the app-side copy still holds the old
    // value and the badge could never move off it.
    await tester.pumpWidget(
      _wrap(
        repo,
        const ClientRecord(id: 'c1', name: 'Acme', waveSyncState: 'synced'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Synced with Wave'), findsOneWidget);

    live.add(
      const ClientRecord(id: 'c1', name: 'Acme', waveSyncState: 'pending'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sync pending'), findsOneWidget);
    expect(find.text('Synced with Wave'), findsNothing);

    // ...and back again once the outbox reaches Wave, with no user action.
    live.add(
      const ClientRecord(id: 'c1', name: 'Acme', waveSyncState: 'synced'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Synced with Wave'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed live read keeps the handed-in record on screen', (
    tester,
  ) async {
    when(
      () => repo.watchClient('c1'),
    ).thenAnswer((_) => Stream<ClientRecord?>.error(Exception('denied')));

    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(repo, const ClientRecord(id: 'c1', name: 'Acme', phone: '555-1')),
    );
    await tester.pumpAndSettle();

    // Offline or refused must never blank the detail.
    expect(find.text('Acme'), findsOneWidget);
    expect(find.text('555-1'), findsOneWidget);
  });

  testWidgets('the additional contacts section is always available in edit', (
    tester,
  ) async {
    await _pumpInEditMode(tester, repo, _personClient);

    expect(find.text('Additional contacts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing a client prefills its extra contacts', (tester) async {
    await _pumpInEditMode(tester, repo, _clientWithContacts);

    expect(find.widgetWithText(TextField, 'Bob Builder'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving rebuilds contacts from the edited contact cards', (
    tester,
  ) async {
    when(() => repo.updateClient(any())).thenAnswer((_) async {});
    await _pumpInEditMode(tester, repo, _clientWithContacts);

    // The customer's own phone is the first Phone field; the contact card's
    // phone is the second.
    await tester.enterText(_textFieldFor('Phone').first, '5145559999');
    // Let SheetFocusScroll's 280 ms focus-scroll timer fire.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(_sheetSave());
    await tester.pumpAndSettle();

    final saved =
        verify(() => repo.updateClient(captureAny())).captured.single
            as ClientRecord;
    // The customer's own phone changed; the extra contact is unchanged.
    expect(saved.phone, '(514) 555-9999');
    expect(saved.contacts, const [
      ClientContact(name: 'Bob Builder', phone: '555-0202'),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('view mode shows quick actions only for available details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // _clientWithContacts has a phone and an address but no email.
    await tester.pumpWidget(_wrap(repo, _clientWithContacts));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(InkWell, 'Call'), findsOneWidget);
    expect(find.widgetWithText(InkWell, 'Directions'), findsOneWidget);
    expect(find.widgetWithText(InkWell, 'Email'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'view mode always offers Save to contacts, even with no details',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // A name-only client has no phone / email / address.
      await tester.pumpWidget(
        _wrap(repo, const ClientRecord(id: 'c3', name: 'Eve')),
      );
      await tester.pumpAndSettle();

      // It is a labelled row below the info panel now, not a tile.
      expect(find.text('Save to contacts'), findsOneWidget);
      expect(find.widgetWithText(InkWell, 'Call'), findsNothing);
      expect(find.widgetWithText(InkWell, 'Directions'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('view mode lists the extra contacts', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(repo, _clientWithContacts));
    await tester.pumpAndSettle();

    // The extra contact is listed.
    expect(find.text('Bob Builder'), findsOneWidget);
    // The customer's own phone shows once (contact-info card).
    expect(find.text('555-0101'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('view mode shows the saved changes without reopening', (
    tester,
  ) async {
    when(() => repo.updateClient(any())).thenAnswer((_) async {});
    await _pumpInEditMode(tester, repo, _clientWithContacts);

    await tester.enterText(_textFieldFor('Phone').first, '5145559999');
    // Let SheetFocusScroll's 280 ms focus-scroll timer fire.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(_sheetSave());
    await tester.pumpAndSettle();

    // Back in view mode (no edit fields) with the new phone rendered.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('(514) 555-9999'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing an extra contact persists the removal', (tester) async {
    when(() => repo.updateClient(any())).thenAnswer((_) async {});
    await _pumpInEditMode(tester, repo, _clientWithContacts);

    // Remove the extra "Bob Builder" contact card.
    await tester.tap(find.byTooltip('Remove contact'));
    await tester.pumpAndSettle();
    await tester.tap(_sheetSave());
    await tester.pumpAndSettle();

    final saved =
        verify(() => repo.updateClient(captureAny())).captured.single
            as ClientRecord;
    expect(saved.contacts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the three action tiles', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(
        repo,
        const ClientRecord(
          id: 'c1',
          name: 'Acme',
          phone: '5145551234',
          address: '12 Main St',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Call'), findsOneWidget);
    expect(find.text('Directions'), findsOneWidget);
    expect(find.text('Book job'), findsOneWidget);
  });

  testWidgets('omits empty info rows instead of showing placeholders', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(
        repo,
        const ClientRecord(id: 'c1', name: 'Acme', phone: '5145551234'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PHONE'), findsOneWidget);
    // No address, manager or billing on this record — those keys must not render.
    expect(find.text('ADDRESS'), findsNothing);
    expect(find.text('MANAGER'), findsNothing);
    expect(find.text('BILLING'), findsNothing);
    expect(find.textContaining('None'), findsNothing);
  });

  testWidgets('renders the manager and billing rows when present', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(
        repo,
        const ClientRecord(
          id: 'c1',
          name: 'Acme',
          onSiteManager: 'Dana',
          billingTerms: 'Net 30',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MANAGER'), findsOneWidget);
    expect(find.text('Dana'), findsOneWidget);
    expect(find.text('BILLING'), findsOneWidget);
    expect(find.text('Net 30'), findsOneWidget);
  });

  testWidgets('auto-invoice joins the billing line', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(
        repo,
        const ClientRecord(
          id: 'c1',
          name: 'Acme',
          billingTerms: 'Net 30',
          autoInvoice: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Net 30 · Invoice automatically'), findsOneWidget);
  });

  testWidgets('the footer offers Archive, and withholds Delete for a client '
      'with history', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(repo, const ClientRecord(id: 'c1', name: 'Acme', jobCount: 4)),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Archive'), findsOneWidget);
    // The callable would refuse this delete, so the footer must not offer it.
    expect(find.widgetWithText(OutlinedButton, 'Delete'), findsNothing);
  });

  testWidgets('the footer offers Delete for a client with no jobs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(repo, const ClientRecord(id: 'c1', name: 'Acme', jobCount: 0)),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Delete'), findsOneWidget);
  });

  testWidgets('an archived client is offered Unarchive instead', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(
        repo,
        ClientRecord.fromMap('c1', {'name': 'Acme', 'archived': true}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Unarchive'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Archive'), findsNothing);
  });

  testWidgets('the profile card marks an archived client', (tester) async {
    // Only the footer button used to flip, so the card read as a live client.
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(
        repo,
        ClientRecord.fromMap('c1', {'name': 'Acme', 'archived': true}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archived'), findsOneWidget);
  });

  testWidgets('archiving keeps the view open and flips the button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    when(
      () => repo.setClientArchived(any(), archived: any(named: 'archived')),
    ).thenAnswer((_) async {});

    await tester.pumpWidget(
      _wrap(repo, const ClientRecord(id: 'c1', name: 'Acme', jobCount: 4)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Archive'));
    await tester.pumpAndSettle();

    // Archiving is reversible from where it was taken — the record still
    // exists, so this surface must not dismiss itself.
    verify(() => repo.setClientArchived('c1', archived: true)).called(1);
    expect(find.widgetWithText(OutlinedButton, 'Unarchive'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the profile card states the type and the month joined', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(
        repo,
        ClientRecord(
          id: 'c1',
          name: 'Gestion Beauchemin',
          type: ClientType.building,
          createdAt: DateTime(2023, 4, 2),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Gestion Beauchemin'), findsOneWidget);
    expect(find.text('Building · since Apr 2023'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
  });

  testWidgets('the profile card drops the half it has no data for', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(
        repo,
        ClientRecord(id: 'c1', name: 'Acme', createdAt: DateTime(2023, 4, 2)),
      ),
    );
    await tester.pumpAndSettle();

    // No type on this record, so the line is the join fragment alone.
    expect(find.text('since Apr 2023'), findsOneWidget);
  });

  testWidgets('a typeless client with no createdAt renders no subtitle line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(repo, const ClientRecord(id: 'c1', name: 'Acme')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('since'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
