import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/widgets/sheets/inline_add_client_host.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/sheets/add_client_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../../../support/tour_test_support.dart';

class _FakeClientsRepository implements ClientsRepository {
  int addCalls = 0;

  @override
  Future<ClientRecord> addClient(ClientRecord client) async {
    addCalls++;
    return client.copyWith(id: 'new-id');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with InlineAddClientHost<_Host> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ElevatedButton(
        onPressed: () => requestAddClient('Marc Tremblay'),
        child: const Text('add'),
      ),
    );
  }
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    markFormToursSeen();
  });

  Future<void> setTallViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<_FakeClientsRepository> pumpHost(WidgetTester tester) async {
    await setTallViewport(tester);
    final repo = _FakeClientsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: _Host(),
        ),
      ),
    );
    return repo;
  }

  testWidgets('two requests within one frame open only one add-client sheet', (
    tester,
  ) async {
    await pumpHost(tester);

    // Two taps with no `pump()` between them — the shape a fast second tap
    // produces before the sheet's 80ms settle raises the modal barrier.
    await tester.tap(find.byType(ElevatedButton));
    await tester.tap(find.byType(ElevatedButton));

    // Settles the 80ms SheetFocus delay and the sheet's open animation.
    await tester.pumpAndSettle();

    expect(find.byType(AddClientSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the guard releases after the sheet closes, so a later tap opens a '
    'fresh one',
    (tester) async {
      await pumpHost(tester);

      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();
      expect(find.byType(AddClientSheet), findsOneWidget);

      Navigator.of(tester.element(find.byType(AddClientSheet))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(AddClientSheet), findsNothing);

      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();

      expect(find.byType(AddClientSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
