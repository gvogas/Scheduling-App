import 'package:scheduling/features/employees/domain/models/employee_record.dart';

/// Whether to show the one-time "Be on the team map" page.
bool shouldAskToShareLocation({
  required EmployeeRecord? me,
  required bool alreadyAsked,
  required bool calendarTourPending,
}) =>
    me != null &&
    me.uid.isNotEmpty &&
    me.isActive &&
    !me.isTestAccount &&
    !me.locationSharingEnabled &&
    !alreadyAsked &&
    !calendarTourPending;
