import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/views/client_detail_view.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockClientsRepo extends Mock implements ClientsRepository {}

/// The detail view holds a live listener on its doc.
_MockClientsRepo _quietRepo() {
  final repo = _MockClientsRepo();
  when(
    () => repo.watchClient(any()),
  ).thenAnswer((_) => const Stream<ClientRecord?>.empty());
  return repo;
}

const _client = ClientRecord(
  id: 'c1',
  name: 'Carol Smith',
  phone: '555-0303',
  address: '2 Main St',
);

void main() {
  testWidgets(
    'client detail view does not overflow on small width at 2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clientsRepositoryProvider.overrideWithValue(_quietRepo()),
          ],
          child: ThemeNotifier(
            themeMode: ThemeMode.light,
            toggleTheme: () {},
            textScale: 2,
            setTextScale: (_) {},
            setLanguage: (_) {},
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: lightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child ?? const SizedBox.shrink(),
              ),
              home: const Scaffold(body: ClientDetailView(client: _client)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );
}
