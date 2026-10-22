import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/features/clients/application/client_form_controller.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/data/contact_link_store.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';

class _MockClientsRepo extends Mock implements ClientsRepository {}

class _MockContactLinkStore extends Mock implements ContactLinkStore {}

const _client = ClientRecord(
  id: 'c1',
  name: 'Jane Doe',
  phone: '555-0001',
  address: '123 Main St',
);

void main() {
  setUpAll(() {
    registerFallbackValue(_client);
  });

  late _MockClientsRepo repo;
  late _MockContactLinkStore linkStore;
  late ProviderContainer container;
  late List<ClientsWrite?> writes;

  setUp(() {
    repo = _MockClientsRepo();
    linkStore = _MockContactLinkStore();
    writes = [];

    // No linked phone contact by default: the best-effort sync exits before
    // touching any platform channel.
    when(() => linkStore.contactIdFor(any())).thenAnswer((_) async => null);
    when(() => linkStore.unlink(any())).thenAnswer((_) async {});

    container = ProviderContainer(
      overrides: [
        clientsRepositoryProvider.overrideWithValue(repo),
        contactLinkStoreProvider.overrideWithValue(linkStore),
        // Deterministic online by default; the offline tests build their own.
        isOfflineProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    container.listen(clientsRefreshProvider, (_, write) => writes.add(write));
  });

  ClientFormController offlineNotifier() {
    final offline = ProviderContainer(
      overrides: [
        clientsRepositoryProvider.overrideWithValue(repo),
        contactLinkStoreProvider.overrideWithValue(linkStore),
        isOfflineProvider.overrideWithValue(true),
      ],
    );
    addTearDown(offline.dispose);
    return offline.read(clientFormControllerProvider.notifier);
  }

  ClientFormController notifier() =>
      container.read(clientFormControllerProvider.notifier);

  int refreshCount() => writes.length;

  group('addClient', () {
    test('persists, bumps the list refresh and reports saved with the '
        'generated id', () async {
      final persisted = _client.copyWith(id: 'c1-persisted');
      when(() => repo.addClient(any())).thenAnswer((_) async => persisted);

      final outcome = await notifier().addClient(_client);

      expect(outcome, isA<ClientSaved>());
      // The controller surfaces the repository's id-populated record, not the
      // input (whose id may be empty), so the caller can link to it.
      expect((outcome as ClientSaved).client, persisted);
      verify(() => repo.addClient(_client)).called(1);
      // Typed, so the list can tell "refresh" from "patch this row".
      expect(writes.single, isA<ClientsWriteAdded>());
      // Resets on success — the detail pane keeps this shared provider alive
      // after the sheet pops, so a lingering isSaving would disable add/edit forms all session.
      expect(container.read(clientFormControllerProvider), isFalse);
    });

    test('reports the failure without bumping the refresh', () async {
      when(() => repo.addClient(any())).thenThrow(Exception('offline'));

      final outcome = await notifier().addClient(_client);

      expect(outcome, isA<ClientSaveFailed>());
      expect(refreshCount(), 0);
      expect(container.read(clientFormControllerProvider), isFalse);
    });

    test('a double-tapped add returns Busy, not a failure', () async {
      // The three save controllers all used to return
      // `XSaveFailed(SocketException('in-flight'))` here, and `_classifyError`
      // keys on the SocketException TYPE — so a double-tap rendered "you
      // appear to be offline" while perfectly online, with the real save
      // succeeding behind the error. This was the one Busy member with no
      // assertion, so it was the one that could regress back.
      final gate = Completer<ClientRecord>();
      when(() => repo.addClient(any())).thenAnswer((_) => gate.future);

      final first = notifier().addClient(_client);
      final second = await notifier().addClient(_client);

      expect(second, isA<ClientSaveBusy>());
      gate.complete(_client.copyWith(id: 'c1-persisted'));
      await first;
      verify(() => repo.addClient(any())).called(1);
    });

    test('offline fails fast without touching the repo', () async {
      final outcome = await offlineNotifier().addClient(_client);

      expect(outcome, isA<ClientSaveFailed>());
      expect((outcome as ClientSaveFailed).error, isA<SocketException>());
      verifyNever(() => repo.addClient(any()));
      expect(refreshCount(), 0);
    });
  });

  group('updateClient', () {
    test('persists, bumps the refresh, syncs the linked contact and '
        'reports saved', () async {
      when(() => repo.updateClient(any())).thenAnswer((_) async {});

      final outcome = await notifier().updateClient(_client);

      expect(outcome, isA<ClientSaved>());
      verify(() => repo.updateClient(_client)).called(1);
      verify(() => linkStore.contactIdFor('c1')).called(1);
      // The list patches the saved record into its page in place.
      expect(
        writes.single,
        isA<ClientsWriteUpdated>().having((w) => w.client, 'client', _client),
      );
      expect(container.read(clientFormControllerProvider), isFalse);
    });

    test('a failing contact-link lookup never fails the save', () async {
      when(() => repo.updateClient(any())).thenAnswer((_) async {});
      when(
        () => linkStore.contactIdFor(any()),
      ).thenAnswer((_) async => throw Exception('prefs flake'));

      final outcome = await notifier().updateClient(_client);

      expect(outcome, isA<ClientSaved>());
      expect(refreshCount(), 1);
    });

    test('reports the failure without bumping the refresh', () async {
      when(() => repo.updateClient(any())).thenThrow(Exception('offline'));

      final outcome = await notifier().updateClient(_client);

      expect(outcome, isA<ClientSaveFailed>());
      expect(refreshCount(), 0);
      verifyNever(() => linkStore.contactIdFor(any()));
      expect(container.read(clientFormControllerProvider), isFalse);
    });

    test('offline fails fast without touching the repo', () async {
      final outcome = await offlineNotifier().updateClient(_client);

      expect(outcome, isA<ClientSaveFailed>());
      expect((outcome as ClientSaveFailed).error, isA<SocketException>());
      verifyNever(() => repo.updateClient(any()));
      verifyNever(() => linkStore.contactIdFor(any()));
      expect(refreshCount(), 0);
    });
  });

  group('setArchived', () {
    test('archives, bumps the refresh and reports the new state', () async {
      when(
        () => repo.setClientArchived(any(), archived: any(named: 'archived')),
      ).thenAnswer((_) async {});

      final outcome = await notifier().setArchived('c1', archived: true);

      expect(outcome, isA<ClientArchived>());
      expect((outcome as ClientArchived).archived, isTrue);
      verify(() => repo.setClientArchived('c1', archived: true)).called(1);
      expect(
        writes.single,
        isA<ClientsWriteArchived>()
            .having((w) => w.clientId, 'clientId', 'c1')
            .having((w) => w.archived, 'archived', isTrue),
      );
      expect(container.read(clientFormControllerProvider), isFalse);
    });

    test('un-archives through the same action', () async {
      when(
        () => repo.setClientArchived(any(), archived: any(named: 'archived')),
      ).thenAnswer((_) async {});

      final outcome = await notifier().setArchived('c1', archived: false);

      expect((outcome as ClientArchived).archived, isFalse);
      verify(() => repo.setClientArchived('c1', archived: false)).called(1);
    });

    test('reports the failure without bumping the refresh', () async {
      when(
        () => repo.setClientArchived(any(), archived: any(named: 'archived')),
      ).thenThrow(Exception('boom'));

      final outcome = await notifier().setArchived('c1', archived: true);

      expect(outcome, isA<ClientArchiveFailed>());
      expect(refreshCount(), 0);
      expect(container.read(clientFormControllerProvider), isFalse);
    });

    test('a double-tapped archive returns Busy, not a second write', () async {
      // The last unexercised member of the family. Archive is a toggle, so a
      // second write while the first is in flight is a state flip nobody
      // asked for; and Busy must surface NOTHING, where a fabricated
      // `SocketException` would render "you appear to be offline".
      final gate = Completer<void>();
      when(
        () => repo.setClientArchived(any(), archived: any(named: 'archived')),
      ).thenAnswer((_) => gate.future);

      final first = notifier().setArchived('c1', archived: true);
      final second = await notifier().setArchived('c1', archived: true);

      expect(second, isA<ClientArchiveBusy>());
      gate.complete();
      await first;
      verify(
        () => repo.setClientArchived(any(), archived: any(named: 'archived')),
      ).called(1);
      expect(refreshCount(), 1);
    });
  });
}
