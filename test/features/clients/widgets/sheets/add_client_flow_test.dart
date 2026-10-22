import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/widgets/sheets/add_appointment_sheet.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/widgets/sheets/add_client_flow.dart';
import 'package:scheduling/features/clients/widgets/sheets/client_detail_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../../../support/tour_test_support.dart';

class _FakeClientsRepository implements ClientsRepository {
  List<ClientRecord> onFile = const [];

  @override
  Future<ClientRecord> addClient(ClientRecord client) async =>
      client.copyWith(id: 'new-id');

  @override
  Future<List<ClientRecord>> searchClients(
    String query, {
    ClientsFilter filter = const ClientsFilterAll(),
  }) async => onFile;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _jane = ClientRecord(id: 'x1', name: 'Jane Doe', phone: '(514) 555-0000');

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    markFormToursSeen();
  });

  ClientRecord? flowResult;

  Future<void> openFlow(
    WidgetTester tester, {
    required Size size,
    List<ClientRecord> onFile = const [],
  }) async {
    flowResult = null;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeClientsRepository()..onFile = onFile;
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
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async =>
                      flowResult = await runAddClientFlow(context),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  Future<void> typePhone(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone'),
      '5145550000',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  Future<void> fillAndTap(WidgetTester tester, String verb) async {
    await tester.enterText(find.byType(TextField).first, 'Acme');
    await typePhone(tester);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text(verb));
    await tester.pumpAndSettle();
  }

  const phone = Size(500, 2400);
  const tablet = Size(800, 2400);

  testWidgets('plain Add returns the client and opens nothing further', (
    tester,
  ) async {
    await openFlow(tester, size: phone);
    await fillAndTap(tester, 'Add');

    expect(flowResult?.id, 'new-id');
    expect(find.byType(AddEventSheet), findsNothing);
    expect(find.byType(ClientDetailSheet), findsNothing);
  });

  testWidgets('Add and book a job opens the booking sheet', (tester) async {
    await openFlow(tester, size: phone);
    await fillAndTap(tester, 'Add and book a job');

    // The flow is still awaiting the booking sheet, so it has not resolved.
    expect(find.byType(AddEventSheet), findsOneWidget);
  });

  testWidgets('Open on a phone layout shows the existing client sheet', (
    tester,
  ) async {
    await openFlow(tester, size: phone, onFile: const [_jane]);
    await typePhone(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(ClientDetailSheet), findsOneWidget);
  });

  testWidgets('Open on a two-pane layout leaves selection to the host', (
    tester,
  ) async {
    await openFlow(tester, size: tablet, onFile: const [_jane]);
    await typePhone(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(flowResult?.id, 'x1');
    expect(find.byType(ClientDetailSheet), findsNothing);
  });
}
