import 'package:flutter/widgets.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_prefill.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/sheets/add_client_sheet.dart';
import 'package:scheduling/features/clients/widgets/sheets/client_detail_sheet.dart';

/// The add-client → book-a-job flow, in one place. Returns the client the
/// sheet handed back — created, or an existing one the duplicate-phone row
/// opened — so a two-pane host can select it.
Future<ClientRecord?> runAddClientFlow(BuildContext context) async {
  final result = await showAddClientSheet(
    context,
    analyticsSource: AnalyticsSources.clientsTab,
  );
  if (result == null || !context.mounted) return result?.client;
  switch (result.next) {
    case AddClientNext.none:
      break;
    case AddClientNext.bookJob:
      await showAddEventPopup(
        context,
        prefill: AppointmentPrefill(client: result.client),
      );
    case AddClientNext.openExisting:
      // A two-pane host selects it into the detail pane instead.
      if (!context.isTwoPane) {
        await showClientDetailSheet(context, result.client);
      }
  }
  return result.client;
}
