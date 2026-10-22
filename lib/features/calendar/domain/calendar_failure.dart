import 'package:flutter/widgets.dart';

import 'package:scheduling/core/errors/failure.dart';
import 'package:scheduling/l10n/l10n.dart';

sealed class CalendarFailure extends Failure {
  const CalendarFailure();
}

/// `saveAppointmentEdits` refused a `checkConflicts` save: someone in the crew
/// is already booked over [start]–[end]. Both save controllers turn it into
/// their busy outcome, so the message here is only a fallback.
class CalendarFailureEmployeesBusy extends CalendarFailure {
  const CalendarFailureEmployeesBusy({
    required this.busyEmployeeIds,
    required this.start,
    required this.end,
  });

  final List<String> busyEmployeeIds;
  final DateTime start;
  final DateTime end;

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.calendar_scheduleConflict;
}
