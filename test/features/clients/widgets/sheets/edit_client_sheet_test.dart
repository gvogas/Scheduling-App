import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/widgets/sheets/edit_client_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClientsRepo extends Mock implements ClientsRepository {}

Widget _harness(ClientsRepository repo, ClientRecord client) => ProviderScope(
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
      home: Scaffold(body: EditClientSheet(client: client)),
    ),
  ),
);

Finder _fieldFor(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is LabeledTextField && w.label == label),
  matching: find.byType(TextField),
);

Future<void> _pump(
  WidgetTester tester,
  ClientsRepository repo,
  ClientRecord client,
) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_harness(repo, client));
  await tester.pumpAndSettle();
}

ClientRecord _savedFrom(_MockClientsRepo repo) =>
    verify(() => repo.updateClient(captureAny())).captured.single
        as ClientRecord;

void main() {
  late _MockClientsRepo repo;

  setUpAll(() => registerFallbackValue(const ClientRecord(id: '')));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    repo = _MockClientsRepo();
    when(() => repo.updateClient(any())).thenAnswer((_) async {});
  });

  testWidgets('SINCE renders from createdAt and is read-only', (tester) async {
    await _pump(
      tester,
      repo,
      ClientRecord(id: 'c1', name: 'Acme', createdAt: DateTime(2023, 4, 2)),
    );

    expect(find.text('SINCE'), findsOneWidget);
    // Read-only: no editable field carries the date.
    expect(find.widgetWithText(TextField, '2023'), findsNothing);
  });

  testWidgets('a client with no createdAt omits the SINCE row', (tester) async {
    await _pump(tester, repo, const ClientRecord(id: 'c1', name: 'Acme'));

    expect(find.text('SINCE'), findsNothing);
  });

  testWidgets('saving keeps the Wave projection fields untouched', (
    tester,
  ) async {
    await _pump(
      tester,
      repo,
      const ClientRecord(
        id: 'c1',
        name: 'Acme',
        phone: '5145550000',
        noFixedAddress: true,
        waveCustomerId: 'wave-1',
        waveSyncState: 'synced',
      ),
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = _savedFrom(repo);
    expect(saved.waveCustomerId, 'wave-1');
    expect(saved.waveSyncState, 'synced');
  });

  testWidgets('saving carries the function-owned jobCount through untouched', (
    tester,
  ) async {
    await _pump(
      tester,
      repo,
      const ClientRecord(
        id: 'c1',
        name: 'Acme',
        phone: '5145550000',
        noFixedAddress: true,
        jobCount: 12,
      ),
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(_savedFrom(repo).jobCount, 12);
  });

  testWidgets('a lifted number cleared from the phone comes back on save', (
    tester,
  ) async {
    await _pump(
      tester,
      repo,
      const ClientRecord(id: 'c1', name: 'Acme', noFixedAddress: true),
    );

    await tester.enterText(_fieldFor('Name or business'), 'Acme 5145551234');
    await tester.enterText(_fieldFor('Phone'), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(_savedFrom(repo).phone, '(514) 555-1234');
  });

  // I4: these tests asserted `saved.phone` heavily and never once asserted
  // `saved.name` — the field that IS the Wave customer name, and the one an
  // ordinary save can silently rename on live invoices.
  group('the stored name is the Wave customer name', () {
    testWidgets('a PERSON is stored as their phone number', (tester) async {
      await _pump(
        tester,
        repo,
        const ClientRecord(
          id: 'c1',
          name: '(514) 555-0101',
          firstName: 'Marc',
          lastName: 'Tremblay',
          phone: '(514) 555-0101',
          noFixedAddress: true,
        ),
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(_savedFrom(repo).name, '5145550101');
    });

    testWidgets('a BUSINESS keeps its name, never its number', (tester) async {
      // The expensive mistake: the sheet must seed from `baseNameFor` and pass
      // `type`, or saving renames "Vogas Plumbing" to a phone number in Wave.
      await _pump(
        tester,
        repo,
        const ClientRecord(
          id: 'c1',
          name: 'Vogas Plumbing',
          firstName: 'Marc',
          lastName: 'Tremblay',
          phone: '(514) 555-0101',
          type: ClientType.commercial,
          noFixedAddress: true,
        ),
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(_savedFrom(repo).name, 'Vogas Plumbing');
    });

    testWidgets('a legacy "<name> <number>" doc does not stack', (
      tester,
    ) async {
      // The idempotence that makes every ordinary save and the backfill safe
      // to re-run. A doc still in the pre-2026-08-14 shape must come back as
      // the bare number alone — never "Marc Tremblay (514) 555-0101 …".
      await _pump(
        tester,
        repo,
        const ClientRecord(
          id: 'c1',
          name: 'Marc Tremblay (514) 555-0101',
          firstName: 'Marc',
          lastName: 'Tremblay',
          phone: '(514) 555-0101',
          noFixedAddress: true,
        ),
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(_savedFrom(repo).name, '5145550101');
    });
  });

  group('mobile consolidation', () {
    testWidgets('mobile-only becomes the phone and mobile clears', (
      tester,
    ) async {
      await _pump(
        tester,
        repo,
        const ClientRecord(
          id: 'c1',
          name: 'Acme',
          mobile: '4385550199',
          noFixedAddress: true,
        ),
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = _savedFrom(repo);
      expect(saved.phone, '4385550199');
      expect(saved.mobile, isEmpty);
    });

    testWidgets('both set keeps the phone and clears the mobile', (
      tester,
    ) async {
      await _pump(
        tester,
        repo,
        const ClientRecord(
          id: 'c1',
          name: 'Acme',
          phone: '5145550101',
          mobile: '4385550199',
          noFixedAddress: true,
        ),
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = _savedFrom(repo);
      expect(saved.phone, '5145550101');
      expect(saved.mobile, isEmpty);
    });

    testWidgets('phone-only is unchanged', (tester) async {
      await _pump(
        tester,
        repo,
        const ClientRecord(
          id: 'c1',
          name: 'Acme',
          phone: '5145550101',
          noFixedAddress: true,
        ),
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = _savedFrom(repo);
      expect(saved.phone, '5145550101');
      expect(saved.mobile, isEmpty);
    });
  });

  testWidgets('the new P3 fields round-trip through the save', (tester) async {
    await _pump(
      tester,
      repo,
      const ClientRecord(
        id: 'c1',
        name: 'Acme',
        phone: '5145550000',
        noFixedAddress: true,
        type: ClientType.commercial,
        onSiteManager: 'Dana',
        billingTerms: 'Net 30',
        autoInvoice: true,
      ),
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = _savedFrom(repo);
    expect(saved.type, ClientType.commercial);
    expect(saved.onSiteManager, 'Dana');
    expect(saved.billingTerms, 'Net 30');
    expect(saved.autoInvoice, isTrue);
  });

  testWidgets('an empty name blocks the save', (tester) async {
    await _pump(
      tester,
      repo,
      const ClientRecord(
        id: 'c1',
        name: 'Acme',
        phone: '5145550000',
        noFixedAddress: true,
      ),
    );

    await tester.enterText(_fieldFor('Name or business'), '');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    verifyNever(() => repo.updateClient(any()));
  });

  testWidgets('the sheet offers no archive or delete action', (tester) async {
    await _pump(tester, repo, const ClientRecord(id: 'c1', name: 'Acme'));

    // Clients are never removed (owner decision 2026-08-01).
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Archive client'), findsNothing);
  });
}
