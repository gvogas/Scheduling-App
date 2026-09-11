import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/widgets/cards/client_tile.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

Widget _harness(ClientRecord client, {Future<void> Function()? onOpen}) =>
    ThemeNotifier(
  themeMode: ThemeMode.light,
  toggleTheme: () {},
  textScale: 1,
  setTextScale: (_) {},
  setLanguage: (_) {},
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: lightTheme(),
    home: Scaffold(
      body: ClientTile(client: client, onOpen: onOpen),
    ),
  ),
);

void main() {
  testWidgets('shows the address as the subtitle', (tester) async {
    await tester.pumpWidget(
      _harness(
        const ClientRecord(id: 'c1', name: 'Acme', address: '12 Main St'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Acme'), findsOneWidget);
    expect(find.text('12 Main St'), findsOneWidget);
  });

  testWidgets('falls back to the phone when there is no address', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const ClientRecord(id: 'c1', name: 'Acme', phone: '514-555-0101'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('514-555-0101'), findsOneWidget);
  });

  testWidgets('renders an avatar for the client', (tester) async {
    await tester.pumpWidget(
      _harness(const ClientRecord(id: 'c1', name: 'Acme')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppAvatar), findsOneWidget);
  });

  testWidgets('tapping the row opens the client', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _harness(
        const ClientRecord(id: 'c1', name: 'Acme'),
        onOpen: () async => tapped = true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ClientTile));
    await tester.pump();

    expect(tapped, isTrue);
  });

  testWidgets('an archived client shows the Archived pill', (tester) async {
    await tester.pumpWidget(
      _harness(ClientRecord.fromMap('c1', {'name': 'Acme', 'archived': true})),
    );
    await tester.pumpAndSettle();

    // Archived clients still turn up in search, so the row has to say so.
    expect(find.text('Archived'), findsOneWidget);
  });

  testWidgets('an active client shows no Archived pill', (tester) async {
    await tester.pumpWidget(
      _harness(ClientRecord.fromMap('c1', {'name': 'Acme'})),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archived'), findsNothing);
  });

  testWidgets('renders the job count when the trigger has written it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const ClientRecord(id: 'c1', name: 'Acme', jobCount: 12)),
    );
    await tester.pumpAndSettle();

    expect(find.text('12'), findsOneWidget);
    expect(find.text('JOBS'), findsOneWidget);
  });

  testWidgets('renders nothing when the job count is not written yet', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const ClientRecord(id: 'c1', name: 'Acme')),
    );
    await tester.pumpAndSettle();

    // Never "0" — a missing count is unknown, not zero.
    expect(find.text('0'), findsNothing);
    expect(find.text('JOBS'), findsNothing);
  });

  // The type badge came BACK on 2026-09-11 with the fresh three-line row —
  // it has its own corner now rather than competing on one line.
  testWidgets('renders the type badge for a residential client', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const ClientRecord(
          id: 'c1',
          name: 'Acme',
          type: ClientType.residential,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Residential'), findsOneWidget);
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);
  });

  testWidgets('renders the type badge for a commercial client', (tester) async {
    await tester.pumpWidget(
      _harness(
        const ClientRecord(
          id: 'c1',
          name: 'Acme',
          type: ClientType.commercial,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Commercial'), findsOneWidget);
    expect(find.byIcon(Icons.apartment_outlined), findsOneWidget);
  });

  testWidgets('renders the type badge for a building client', (tester) async {
    await tester.pumpWidget(
      _harness(
        const ClientRecord(
          id: 'c1',
          name: 'Acme',
          address: '914-4450 Prom. Paton',
          type: ClientType.building,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Building'), findsOneWidget);
    expect(find.byIcon(Icons.apartment_outlined), findsOneWidget);
  });

  testWidgets('a client with no type shows no badge', (tester) async {
    await tester.pumpWidget(
      _harness(const ClientRecord(id: 'c1', name: 'Acme')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Residential'), findsNothing);
    expect(find.text('Commercial'), findsNothing);
    expect(find.text('Building'), findsNothing);
  });

  testWidgets('the archived badge survives on a small phone at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: _harness(
          const ClientRecord(
            id: 'c1',
            name: 'Acme Property Holdings',
            address: '914-4450 Prom. Paton',
            archived: true,
            type: ClientType.building,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archived'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
