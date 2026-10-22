import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/widgets/fields/client_address_section.dart';
import 'package:scheduling/features/clients/widgets/sheets/add_client_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';

import '../../../../support/tour_test_support.dart';

class _FakeClientsRepository implements ClientsRepository {
  ClientRecord? added;

  /// What the duplicate-phone lookup finds on file.
  List<ClientRecord> onFile = const [];

  @override
  Future<ClientRecord> addClient(ClientRecord client) async {
    added = client;
    return client.copyWith(id: 'new-id');
  }

  @override
  Future<List<ClientRecord>> searchClients(
    String query, {
    ClientsFilter filter = const ClientsFilterAll(),
  }) async => onFile;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    markFormToursSeen();
    _lastResult = null;
  });

  // A viewport tall enough that the whole sheet (a DraggableScrollableSheet at
  // 95% of height) lays out its fields without scrolling, so finders are
  // stable.
  Future<void> setTallViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // The sheet is presented via showModalBottomSheet (as in the app) so
  // FormSheetFrame gets a real sheet route + Material ancestor, and its
  // post-save Navigator.pop has a route to remove.
  Future<_FakeClientsRepository> pumpSheet(
    WidgetTester tester, {
    String? initialName,
    bool showBookAction = true,
  }) async {
    await setTallViewport(tester);
    final repo = _FakeClientsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientsRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: _SheetHost(
            initialName: initialName,
            showBookAction: showBookAction,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('toggling no-fixed-address hides the address section', (
    tester,
  ) async {
    await pumpSheet(tester);
    expect(find.byType(ClientAddressSection), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(find.byType(ClientAddressSection), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a no-fixed-address client saves with an empty address', (
    tester,
  ) async {
    final repo = await pumpSheet(tester);

    // Customer name (first field) satisfies the name requirement; the phone
    // field satisfies the contact-method requirement.
    await tester.enterText(find.byType(TextField).first, 'City of Montreal');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '5145550000',
    );

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added, isNotNull);
    expect(repo.added!.noFixedAddress, isTrue);
    expect(repo.added!.address, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a picked type is stored on the record', (tester) async {
    final repo = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'Acme');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '5145550000',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Commercial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added!.type, ClientType.commercial);
  });

  testWidgets('tapping the selected type chip clears it back to unset', (
    tester,
  ) async {
    final repo = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'Acme');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '5145550000',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Commercial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Commercial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added!.type, ClientType.unset);
  });

  // I4: `repo.added!.name` had zero assertions here, though the stored name IS
  // the Wave customer name — the one field a wrong save renames on live
  // invoices.
  testWidgets('a PERSON is stored under their phone number', (tester) async {
    final repo = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'Marc Tremblay');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '5145550101',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added!.name, '5145550101');
  });

  testWidgets('a PERSON keeps the typed name in the halves', (tester) async {
    // Name is required here and both halves are optional, so composing alone
    // would leave the typed name nowhere — the card would render a bare number
    // and nothing in the app could recover it.
    final repo = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'Marc Tremblay');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '5145550101',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added!.firstName, 'Marc');
    expect(repo.added!.lastName, 'Tremblay');
  });

  // The inline 'add client while booking' flow seeds the name from whatever was
  // typed into the client search — and this business searches people by phone
  // number, so that seed IS the number.
  testWidgets('a seeded phone number is lifted into the phone field', (
    tester,
  ) async {
    final repo = await pumpSheet(tester, initialName: '5145551234');

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added, isNotNull);
    expect(repo.added!.phone, '(514) 555-1234');
  });

  testWidgets('a number typed digit by digit lands whole in the phone field', (
    tester,
  ) async {
    await pumpSheet(tester);

    const number = '5145551234';
    for (var i = 1; i <= number.length; i++) {
      await tester.enterText(
        find.byType(TextField).first,
        number.substring(0, i),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    final phone = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Phone'),
    );
    expect(phone.controller!.text, '(514) 555-1234');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a number cleared from the phone comes back on save', (
    tester,
  ) async {
    final repo = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).first, '5145551234');
    await tester.enterText(find.widgetWithText(TextField, 'Phone'), '');
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added!.phone, '(514) 555-1234');
  });

  // The number already left the name, so only the lift's memory has it.
  testWidgets('a number lifted out of a name comes back on save', (
    tester,
  ) async {
    final repo = await pumpSheet(tester);

    await tester.enterText(
      find.byType(TextField).first,
      'Marc Tremblay 5145551234',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Phone'), '');
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added!.phone, '(514) 555-1234');
  });

  testWidgets('a phone the admin typed is never overwritten by the name', (
    tester,
  ) async {
    await pumpSheet(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '4385550000',
    );
    await tester.enterText(find.byType(TextField).first, '5145551234');
    await tester.pumpAndSettle();

    final phone = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Phone'),
    );
    expect(phone.controller!.text, '(438) 555-0000');
  });

  testWidgets('a seeded name and number lands the name in the halves', (
    tester,
  ) async {
    final repo = await pumpSheet(
      tester,
      initialName: 'Marc Tremblay 5145551234',
    );

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added!.phone, '(514) 555-1234');
    expect(repo.added!.firstName, 'Marc');
    expect(repo.added!.lastName, 'Tremblay');
  });

  // The everyday paste: a number in the shape the app itself renders.
  testWidgets('a pasted bracketed number leaves the name clean', (
    tester,
  ) async {
    final repo = await pumpSheet(tester);

    await tester.enterText(
      find.byType(TextField).first,
      'Marc Tremblay (514) 555-1234',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added!.phone, '(514) 555-1234');
    expect(repo.added!.name, '5145551234');
    expect(repo.added!.firstName, 'Marc');
    expect(repo.added!.lastName, 'Tremblay');
  });

  // The stored shape for a PERSON, spelled out end-to-end: `name` is the BARE
  // number, the halves carry the real name, `phone` stays formatted.
  group(
    'a new PERSON always stores name=bare, halves=name, phone=formatted',
    () {
      Future<void> expectStoredShape(
        _FakeClientsRepository repo,
        WidgetTester tester,
      ) async {
        await tester.tap(find.byType(SwitchListTile));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();

        expect(repo.added, isNotNull);
        expect(repo.added!.name, '5145551234');
        expect(repo.added!.firstName, 'Marc');
        expect(repo.added!.lastName, 'Tremblay');
        expect(repo.added!.phone, '(514) 555-1234');
      }

      testWidgets('name typed, number typed into Phone', (tester) async {
        final repo = await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, 'Marc Tremblay');
        await tester.enterText(_fieldLabelled('Phone'), '5145551234');
        await expectStoredShape(repo, tester);
      });

      testWidgets('name and bare number pasted together', (tester) async {
        final repo = await pumpSheet(tester);
        await tester.enterText(
          find.byType(TextField).first,
          'Marc Tremblay 5145551234',
        );
        await expectStoredShape(repo, tester);
      });

      testWidgets('name and BRACKETED number pasted together', (tester) async {
        final repo = await pumpSheet(tester);
        await tester.enterText(
          find.byType(TextField).first,
          'Marc Tremblay (514) 555-1234',
        );
        await expectStoredShape(repo, tester);
      });

      testWidgets('bare number seeded, halves typed', (tester) async {
        final repo = await pumpSheet(tester, initialName: '5145551234');
        await tester.enterText(_fieldLabelled('First name'), 'Marc');
        await tester.enterText(_fieldLabelled('Last name'), 'Tremblay');
        await expectStoredShape(repo, tester);
      });

      // The brackets must not survive into the stored name — `composeStored`
      // reduces it through `bareNumber` even though the FIELD keeps the shape
      // that was pasted.
      testWidgets('BRACKETED number seeded, halves typed', (tester) async {
        final repo = await pumpSheet(tester, initialName: '(514) 555-1234');
        await tester.enterText(_fieldLabelled('First name'), 'Marc');
        await tester.enterText(_fieldLabelled('Last name'), 'Tremblay');
        await expectStoredShape(repo, tester);
      });

      testWidgets('bracketed number typed into Phone, name typed', (
        tester,
      ) async {
        final repo = await pumpSheet(tester);
        await tester.enterText(find.byType(TextField).first, 'Marc Tremblay');
        await tester.enterText(_fieldLabelled('Phone'), '(514) 555-1234');
        await expectStoredShape(repo, tester);
      });
    },
  );

  testWidgets('a COMMERCIAL client keeps its typed name', (tester) async {
    // The type has to reach `composeStored`, or a real company is booked into
    // Wave under a phone number.
    final repo = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'Vogas Plumbing');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '5145550101',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Commercial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added!.name, 'Vogas Plumbing');
  });

  testWidgets('access notes are saved', (tester) async {
    final repo = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'Acme');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '5145550000',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.enterText(_fieldLabelled('Access notes'), 'Gate code 1234');

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added!.accessNotes, 'Gate code 1234');
  });

  testWidgets('an empty name shows the error and does not write', (
    tester,
  ) async {
    final repo = await pumpSheet(tester);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(repo.added, isNull);
    // Save sits in the fixed header, so the errored field is brought into
    // focus rather than left shaking out of view.
    expect(
      tester
          .widget<TextField>(_fieldLabelled('Name or business'))
          .focusNode
          ?.hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the inline source hides Add and book a job', (tester) async {
    await pumpSheet(tester, showBookAction: false);

    expect(find.text('Add and book a job'), findsNothing);
    expect(find.text('Add'), findsOneWidget);
  });

  testWidgets('Cancel on an untouched sheet closes it with no confirm', (
    tester,
  ) async {
    // The seed (and its phone lift) is the baseline, not an edit.
    await pumpSheet(tester, initialName: 'Marc 514-555-0000');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Discard changes?'), findsNothing);
    expect(find.byType(AddClientSheet), findsNothing);
  });

  testWidgets('Cancel on an edited sheet asks before discarding', (
    tester,
  ) async {
    await pumpSheet(tester);
    await tester.enterText(find.byType(TextField).first, 'Acme');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    expect(find.byType(AddClientSheet), findsOneWidget);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(AddClientSheet), findsNothing);
  });

  testWidgets('Add and book a job reports the follow-up action', (
    tester,
  ) async {
    final repo = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'Acme');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '5145550000',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add and book a job'));
    await tester.pumpAndSettle();

    expect(repo.added, isNotNull);
    expect(_lastResult?.next, AddClientNext.bookJob);
  });

  group('duplicate phone', () {
    testWidgets('a number already on file blocks Add until Use anyway', (
      tester,
    ) async {
      // The costliest data error here: a second client is a second Wave
      // customer, created silently.
      final repo = await pumpSheet(tester);
      repo.onFile = const [_jane];
      await tester.enterText(_fieldLabelled('Name or business'), 'Someone');
      await _typeDuplicatePhone(tester);
      expect(find.text('Already on file: Jane Doe'), findsOneWidget);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(repo.added, isNull);
      expect(find.textContaining('already on file'), findsOneWidget);

      await tester.tap(find.text('Use anyway'));
      await tester.pumpAndSettle();
      expect(find.text('Already on file: Jane Doe'), findsNothing);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(repo.added?.phone, '(514) 555-0000');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Open hands the existing client back instead of adding', (
      tester,
    ) async {
      final repo = await pumpSheet(tester);
      repo.onFile = const [_jane];
      await _typeDuplicatePhone(tester);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(repo.added, isNull);
      expect(_lastResult?.client.id, 'x1');
      expect(_lastResult?.next, AddClientNext.openExisting);
    });

    testWidgets('a number nobody has shows no row', (tester) async {
      await pumpSheet(tester);
      await _typeDuplicatePhone(tester);

      expect(find.textContaining('Already on file'), findsNothing);
    });
  });

  testWidgets('the plain Add verb reports no follow-up action', (tester) async {
    await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'Acme');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '5145550000',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(_lastResult?.next, AddClientNext.none);
  });
}

/// Captured from the sheet's pop so the follow-up action can be asserted.
AddClientResult? _lastResult;

const _jane = ClientRecord(id: 'x1', name: 'Jane Doe', phone: '(514) 555-0000');

/// Types a number already on file and lets the debounced lookup land.
Future<void> _typeDuplicatePhone(WidgetTester tester) async {
  await tester.enterText(_fieldLabelled('Phone'), '5145550000');
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// LabeledTextField renders its label outside the TextField, so match on the
/// wrapper and descend — the same shape clients_screen_test uses.
Finder _fieldLabelled(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is LabeledTextField && w.label == label),
  matching: find.byType(TextField),
);

// Hosts the sheet behind a button so opening it creates a poppable modal route
// with the Material ancestor showModalBottomSheet provides.
class _SheetHost extends StatelessWidget {
  const _SheetHost({this.initialName, this.showBookAction = true});

  final String? initialName;
  final bool showBookAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () async {
            _lastResult = await showModalBottomSheet<AddClientResult>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AddClientSheet(
                initialName: initialName,
                analyticsSource: AnalyticsSources.clientsTab,
                showBookAction: showBookAction,
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
  }
}
