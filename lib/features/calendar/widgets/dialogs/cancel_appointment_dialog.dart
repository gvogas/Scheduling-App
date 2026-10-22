import 'package:flutter/material.dart';

import 'package:scheduling/features/calendar/widgets/dialogs/series_scope_dialog.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';

/// Shows a cancel confirmation for an appointment.
///
/// The twin of `showDeleteAppointmentDialog`, and a separate function for the
/// same reason the two actions are separate: cancelling keeps the job in
/// history, deleting does not.
///
/// One day of a multi-day RUN offers the run scope — a crew that finishes early
/// needs to call off days 4 and 5 in one action, and each day is now its own
/// document. Anything else is a plain confirm. A null result means the user
/// backed out.
///
/// Deliberately NOT offered for a repeat series: cancelling every future
/// occurrence of a recurring visit is a different decision from calling off the
/// rest of one job, and nothing has asked for it.
Future<SeriesScopeChoice?> showCancelAppointmentDialog(
  BuildContext context, {
  required bool isRun,
}) async {
  final l = context.l10n;
  if (!isRun) {
    final confirmed = await showConfirmDialog(
      context,
      title: l.calendar_cancelAppointment,
      message: l.calendar_cancelledJobsAreSavedToHistory,
      confirmLabel: l.calendar_cancelAppointment,
      cancelLabel: l.calendar_keepAppointment,
    );
    return confirmed ? SeriesScopeChoice.thisOnly : null;
  }
  return await showSeriesScopeDialog(
    context,
    title: l.calendar_cancelAppointment,
    thisOnlyLabel: l.calendar_cancelThisDayOnly,
    thisAndFutureLabel: l.calendar_cancelThisAndFollowingDays,
    // The scope IS the verb here, so this site keeps one label rather than
    // switching it on the selection — same shape as the delete dialog.
    primaryLabelFor: (_) => l.calendar_cancelAppointment,
    thisOnlyDetail: l.calendar_cancelRunScopeMessage,
    destructive: true,
  );
}
