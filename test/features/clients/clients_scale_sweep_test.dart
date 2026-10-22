// Sweeps the P3 client surfaces at every text scale on a 375×667 small-phone
// viewport, catching RenderFlex overflow before it reaches a device.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/application/appointment_history_providers.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/widgets/cards/client_tile.dart';
import 'package:scheduling/features/clients/widgets/sheets/add_client_sheet.dart';
import 'package:scheduling/features/clients/widgets/sheets/edit_client_sheet.dart';
import 'package:scheduling/features/clients/widgets/views/client_detail_view.dart';
import 'package:scheduling/features/clients/widgets/views/clients_list_view.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../support/tour_test_support.dart';

class _MockClientsRepo extends Mock implements ClientsRepository {}

/// The client detail view holds a live listener on its doc.
_MockClientsRepo _quietRepo() {
  final repo = _MockClientsRepo();
  when(
    () => repo.watchClient(any()),
  ).thenAnswer((_) => const Stream<ClientRecord?>.empty());
  return repo;
}

// In-app text scales from text_size_screen.dart (Small / Medium / Large / XL)
// plus Android system-level 2.0x to catch the worst case.
const _scales = <double>[0.8, 1, 1.2, 1.4, 2];

const _viewport = Size(375, 667);

/// Populates every P3 field, with long Quebec-realistic strings, so the widest
/// rows are the ones under test.
const _fullClient = ClientRecord(
  id: 'c1',
  name: 'Gestion Immobilière Beauchemin-Lafontaine',
  firstName: 'Marie-Ève',
  lastName: 'Beauchemin-Lafontaine',
  phone: '514 555 0134',
  mobile: '438 555 0199',
  email: 'marie-eve@beauchemin-lafontaine.example',
  address: '1234 Boulevard Saint-Laurent',
  city: 'Montréal',
  province: 'QC',
  postalCode: 'H2X 2S8',
  type: ClientType.building,
  accessNotes: 'Gate code 4821, park behind the loading dock.',
  onSiteManager: 'Jean-Philippe Tremblay',
  billingTerms: 'Net 30, deposit on booking',
  autoInvoice: true,
  jobCount: 128,
);

Widget _scaled({
  required Widget home,
  required double scale,
  ClientsRepository? repo,
}) => ProviderScope(
  overrides: [
    clientsRepositoryProvider.overrideWithValue(repo ?? _quietRepo()),
    // The Job History section reads the real appointments repo; serve an empty
    // history so the sweep never reaches Firebase.
    clientJobHistoryProvider.overrideWith(
      (ref, clientId) async => <AppointmentRecord>[],
    ),
  ],
  child: ThemeNotifier(
    themeMode: ThemeMode.light,
    toggleTheme: () {},
    textScale: scale,
    setTextScale: (_) {},
    setLanguage: (_) {},
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child ?? const SizedBox.shrink(),
      ),
      home: home,
    ),
  ),
);

Future<void> _pumpAt(
  WidgetTester tester, {
  required Widget home,
  required double scale,
  ClientsRepository? repo,
}) async {
  tester.view.physicalSize = _viewport * tester.view.devicePixelRatio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_scaled(home: home, scale: scale, repo: repo));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    markFormToursSeen();
  });

  for (final scale in _scales) {
    testWidgets('client detail survives textScale $scale', (tester) async {
      await _pumpAt(
        tester,
        scale: scale,
        home: const Scaffold(body: ClientDetailView(client: _fullClient)),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('new client sheet survives textScale $scale', (tester) async {
      await _pumpAt(
        tester,
        scale: scale,
        home: const Scaffold(
          body: AddClientSheet(analyticsSource: AnalyticsSources.clientsTab),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('edit client sheet survives textScale $scale', (tester) async {
      await _pumpAt(
        tester,
        scale: scale,
        home: const Scaffold(body: EditClientSheet(client: _fullClient)),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('client row survives textScale $scale', (tester) async {
      await _pumpAt(
        tester,
        scale: scale,
        home: const Scaffold(body: ClientTile(client: _fullClient)),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('an archived client row survives textScale $scale', (
      tester,
    ) async {
      // Two pills in one Wrap — the widest the subtitle strip ever gets.
      await _pumpAt(
        tester,
        scale: scale,
        home: Scaffold(
          body: ClientTile(client: _fullClient.copyWith(archived: true)),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('the open swipe pane survives textScale $scale', (
      tester,
    ) async {
      final repo = _MockClientsRepo();
      when(
        () => repo.fetchClientsPage(
          after: any(named: 'after'),
          limit: any(named: 'limit'),
        ),
        // jobCount 0 so BOTH actions render — the widest the pane gets.
      ).thenAnswer((_) async => [_fullClient.copyWith(jobCount: 0)]);

      await _pumpAt(
        tester,
        scale: scale,
        repo: repo,
        home: const Scaffold(
          body: ClientsListView(searchQuery: '', isAdmin: true),
        ),
      );
      await tester.drag(find.byType(ClientTile).first, const Offset(-300, 0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
