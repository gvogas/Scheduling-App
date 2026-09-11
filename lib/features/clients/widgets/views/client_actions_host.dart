import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/features/clients/application/client_form_controller.dart';
import 'package:scheduling/features/clients/domain/clients_failure.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';

/// Archive / delete handlers shared by the clients list and the client detail.
mixin ClientActionsHost<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// Called after a successful archive / un-archive.
  void onClientArchived(ClientRecord client, {required bool archived});

  /// Called after a successful delete, once the record is gone.
  void onClientDeleted(ClientRecord client);

  /// Toggles [client]'s archived state.
  Future<bool> archiveClient(ClientRecord client) async {
    final next = !client.archived;
    if (guardedOffline(
      context,
      ref,
      intro: context.l10n.error_introArchiveClient,
    )) {
      return false;
    }

    final notices = ref.read(noticeServiceProvider);
    final outcome = await ref
        .read(clientFormControllerProvider.notifier)
        .setArchived(client.id, archived: next);
    if (!mounted) return false;
    switch (outcome) {
      // A write the reentrancy guard skipped: nothing committed and nothing
      // failed, so this surfaces nothing at all.
      case ClientArchiveBusy():
        return false;
      case ClientArchived(:final archived):
        // One toggle, one event — the direction is a parameter.
        ref
            .read(analyticsServiceProvider)
            .logClientArchived(
              action: archived
                  ? AnalyticsArchiveActions.archive
                  : AnalyticsArchiveActions.unarchive,
            );
        notices.success(
          archived
              ? context.l10n.clients_archivedNotice(client.displayName)
              : context.l10n.clients_unarchivedNotice(client.displayName),
        );
        onClientArchived(client, archived: archived);
        return true;
      case ClientArchiveFailed(:final error):
        notices.error(
          composeErrorNotice(
            context,
            intro: context.l10n.error_introArchiveClient,
            error: error,
          ),
        );
        return false;
    }
  }

  /// Confirms, then deletes [client].
  Future<void> confirmDeleteClient(ClientRecord client) async {
    final confirmed = await showConfirmDialog(
      context,
      title: context.l10n.clients_deleteTitle,
      message: context.l10n.clients_deleteMessage(client.displayName),
      confirmLabel: context.l10n.common_delete,
    );
    if (!confirmed || !mounted) return;
    if (guardedOffline(
      context,
      ref,
      intro: context.l10n.error_introDeleteClient,
    )) {
      return;
    }

    final notices = ref.read(noticeServiceProvider);
    final outcome = await ref
        .read(clientFormControllerProvider.notifier)
        .deleteClient(client.id);
    if (!mounted) return;
    switch (outcome) {
      // Skipped by the reentrancy guard — nothing committed, nothing failed.
      case ClientDeleteBusy():
        return;
      case ClientDeleted():
        ref.read(analyticsServiceProvider).logClientDeleted();
        notices.success(context.l10n.clients_deletedNotice(client.displayName));
        onClientDeleted(client);
      case ClientDeleteFailed(:final error):
        // The typed branch runs first: "archive it instead" is actionable,
        // where the generic cause+tag notice would not be.
        if (error is ClientsFailure) {
          notices.error(error.toLocalizedMessage(context));
          return;
        }
        notices.error(
          composeErrorNotice(
            context,
            intro: context.l10n.error_introDeleteClient,
            error: error,
          ),
        );
    }
  }
}
