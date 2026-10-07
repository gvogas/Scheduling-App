import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';

class _MockClientsRepo extends Mock implements ClientsRepository {}

void main() {
  late _MockClientsRepo repo;
  late ProviderContainer container;

  setUpAll(() => registerFallbackValue(const ClientsFilterAll()));

  setUp(() {
    repo = _MockClientsRepo();
    container = ProviderContainer(
      overrides: [clientsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
  });

  group('clientSearchProvider', () {
    test('does not hit the repository for a non-searchable query', () async {
      final results = await container.read(
        clientSearchProvider(('   ', const ClientsFilterAll())).future,
      );

      expect(results, isEmpty);
      verifyNever(() => repo.searchClients(any()));
    });

    test('a clientsRefresh bump (e.g. after a delete) refetches committed '
        'search results instead of serving the stale pre-write list', () async {
      const sophie = ClientRecord(id: 'c1', name: 'Sophie Tremblay');
      when(
        () => repo.searchClients(any()),
      ).thenAnswer((_) async => const [sophie]);

      // Keep the provider alive across the bump, like the rendered
      // search-results list does.
      const key = ('sophie', ClientsFilterAll());
      final sub = container.listen(clientSearchProvider(key), (_, _) {});
      addTearDown(sub.close);

      expect(await container.read(clientSearchProvider(key).future), [sophie]);
      verify(() => repo.searchClients('sophie')).called(1);

      // Simulate a delete: the write path bumps clientsRefreshProvider and
      // the repository stops returning the deleted client.
      when(() => repo.searchClients(any())).thenAnswer((_) async => const []);
      container.read(clientsRefreshProvider.notifier).bump();

      expect(await container.read(clientSearchProvider(key).future), isEmpty);
      verify(() => repo.searchClients('sophie')).called(1);
    });
  });
  group('clientsTotalCountProvider', () {
    const commercial = ClientsFilterType(ClientType.commercial);

    test('counts the filter it is keyed on', () async {
      when(
        () => repo.countClients(filter: any(named: 'filter')),
      ).thenAnswer((_) async => 120);

      expect(
        await container.read(clientsTotalCountProvider(commercial).future),
        120,
      );
      verify(() => repo.countClients(filter: commercial)).called(1);
    });

    test('a clientsRefresh bump (archive, delete, save) re-counts', () async {
      when(
        () => repo.countClients(filter: any(named: 'filter')),
      ).thenAnswer((_) async => 120);
      final sub = container.listen(
        clientsTotalCountProvider(commercial),
        (_, _) {},
      );
      addTearDown(sub.close);
      expect(
        await container.read(clientsTotalCountProvider(commercial).future),
        120,
      );

      when(
        () => repo.countClients(filter: any(named: 'filter')),
      ).thenAnswer((_) async => 119);
      container.read(clientsRefreshProvider.notifier).bump();

      expect(
        await container.read(clientsTotalCountProvider(commercial).future),
        119,
      );
    });
  });
}
