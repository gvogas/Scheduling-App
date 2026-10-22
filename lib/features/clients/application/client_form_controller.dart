import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/contact_export_launcher.dart';
import 'package:scheduling/features/clients/data/contact_link_store.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';

/// Outcome of a client add/update. The forms map this to notices or navigation.
sealed class ClientSaveOutcome {
  const ClientSaveOutcome();
}

class ClientSaved extends ClientSaveOutcome {
  const ClientSaved(this.client);
  final ClientRecord client;
}

class ClientSaveFailed extends ClientSaveOutcome {
  const ClientSaveFailed(this.error);
  final Object error;
}

/// A write the reentrancy guard skipped because one is already in flight.
/// Nothing committed and nothing failed, so this surfaces NOTHING. It used to
/// be `ClientSaveFailed(SocketException('in-flight'))`, which
/// `composeErrorNotice` classifies by TYPE and rendered as "you appear to be
/// offline" on a double-tap while perfectly online. The `'offline'` sentinel
/// below is different and stays — there the classification is correct.
class ClientSaveBusy extends ClientSaveOutcome {
  const ClientSaveBusy();
}

/// Outcome of a client delete.
sealed class ClientDeleteOutcome {
  const ClientDeleteOutcome();
}

class ClientDeleted extends ClientDeleteOutcome {
  const ClientDeleted();
}

class ClientDeleteFailed extends ClientDeleteOutcome {
  const ClientDeleteFailed(this.error);
  final Object error;
}

/// A delete the reentrancy guard skipped. Surfaces NOTHING — see
/// [ClientSaveBusy] for why this is a member and not a fabricated exception.
class ClientDeleteBusy extends ClientDeleteOutcome {
  const ClientDeleteBusy();
}

/// Outcome of an archive / un-archive.
sealed class ClientArchiveOutcome {
  const ClientArchiveOutcome();
}

class ClientArchived extends ClientArchiveOutcome {
  const ClientArchived({required this.archived});
  final bool archived;
}

class ClientArchiveFailed extends ClientArchiveOutcome {
  const ClientArchiveFailed(this.error);
  final Object error;
}

/// A write the reentrancy guard skipped. Surfaces NOTHING — see
/// [ClientSaveBusy] for why this is a member and not a fabricated exception.
class ClientArchiveBusy extends ClientArchiveOutcome {
  const ClientArchiveBusy();
}

/// Write orchestration shared by the add/edit/detail views. Handles the
/// repository write, the list refresh, and a best-effort phone-contact sync.
///
/// State is the Save spinner flag, shared by every write here — archive and
/// delete reuse it rather than adding flags of their own.
class ClientFormController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Persists a new client. State resets in the `finally` block because this provider
  /// is shared with the detail pane in the split layout.
  Future<ClientSaveOutcome> addClient(ClientRecord client) async {
    // Reentrancy guard, synchronously before anything else. The primary button
    // only disables on the NEXT frame, and add_client_sheet has two entry points
    // into this same write (the frame's verb and "Add and book a job"), so a
    // double-hit before that rebuild created two client docs.
    if (state) return const ClientSaveBusy();
    // Bail out early if we're offline — Firestore writes block until the server acks,
    // so the button would just spin until reconnect (CLI-ADD maps the exception).
    if (ref.read(isOfflineProvider)) {
      return const ClientSaveFailed(SocketException('offline'));
    }
    // Resolve dependencies before the first await — in Riverpod 3, a disposed notifier's
    // Ref throws if you read it after that point.
    final repo = ref.read(clientsRepositoryProvider);
    final refresh = ref.read(clientsRefreshProvider.notifier);
    final logger = ref.read(loggerProvider);
    state = true;
    try {
      final saved = await repo.addClient(client);
      refresh.bump(ClientsWriteAdded(saved));
      return ClientSaved(saved);
    } catch (e, st) {
      logger.warn('CLI-ADD addClient failed', e, st);
      return ClientSaveFailed(e);
    } finally {
      if (ref.mounted) state = false;
    }
  }

  /// Persists edit and mirrors to phone contact (best-effort, never blocks/fails the save).
  Future<ClientSaveOutcome> updateClient(ClientRecord client) async {
    // See addClient — the guard runs before every other check.
    if (state) return const ClientSaveBusy();
    // Bail out early if we're offline (the edit form shows the CLI-SAVE notice).
    if (ref.read(isOfflineProvider)) {
      return const ClientSaveFailed(SocketException('offline'));
    }
    // Resolved before first await (see addClient).
    final repo = ref.read(clientsRepositoryProvider);
    final refresh = ref.read(clientsRefreshProvider.notifier);
    final logger = ref.read(loggerProvider);
    final linkStore = ref.read(contactLinkStoreProvider);
    state = true;
    try {
      await repo.updateClient(client);
      refresh.bump(ClientsWriteUpdated(client));
      await updateLinkedPhoneContact(
        linkStore: linkStore,
        logger: logger,
        client: client,
      );
      return ClientSaved(client);
    } catch (e, st) {
      logger.warn('CLI-SAVE updateClient failed', e, st);
      return ClientSaveFailed(e);
    } finally {
      if (ref.mounted) state = false;
    }
  }

  /// Archives or un-archives a client. Archived clients leave the paginated
  /// list and the type filter but stay searchable and bookable.
  Future<ClientArchiveOutcome> setArchived(
    String clientId, {
    required bool archived,
  }) async {
    // Reentrancy guard, synchronously before the first await (see addClient).
    if (state) return const ClientArchiveBusy();
    final repo = ref.read(clientsRepositoryProvider);
    final refresh = ref.read(clientsRefreshProvider.notifier);
    final logger = ref.read(loggerProvider);
    state = true;
    try {
      await repo.setClientArchived(clientId, archived: archived);
      refresh.bump(ClientsWriteArchived(clientId, archived: archived));
      return ClientArchived(archived: archived);
    } catch (e, st) {
      logger.warn('CLI-ARCH setArchived failed', e, st);
      return ClientArchiveFailed(e);
    } finally {
      if (ref.mounted) state = false;
    }
  }

  /// Deletes a client and drops its device-local phone-contact link. Refused
  /// server-side when the client still has appointments — archive is the
  /// normal removal.
  Future<ClientDeleteOutcome> deleteClient(String clientId) async {
    // See addClient — the guard runs before every other check. Without it a
    // double-tap fires the callable twice and the second returns
    // `client-not-found`, so a delete that worked reports a success notice
    // immediately followed by an error one.
    if (state) return const ClientDeleteBusy();
    // Resolved before the first await (see addClient).
    final repo = ref.read(clientsRepositoryProvider);
    final refresh = ref.read(clientsRefreshProvider.notifier);
    final logger = ref.read(loggerProvider);
    final linkStore = ref.read(contactLinkStoreProvider);
    state = true;
    try {
      await repo.deleteClient(clientId);
      try {
        await linkStore.unlink(clientId);
      } catch (e, st) {
        logger.warn('CLI-DEL contact unlink failed', e, st);
      }
      refresh.bump(ClientsWriteDeleted(clientId));
      return const ClientDeleted();
    } catch (e, st) {
      logger.warn('CLI-DEL deleteClient failed', e, st);
      return ClientDeleteFailed(e);
    } finally {
      if (ref.mounted) state = false;
    }
  }
}

/// True while a client add, edit or delete is in flight.
final clientFormControllerProvider =
    NotifierProvider.autoDispose<ClientFormController, bool>(
      ClientFormController.new,
    );
