import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

/// Which version of the team-map page a person gets.
enum LocationShareAskVariant { turnOn, openSettings, alreadyOn }

/// Whether this app build still owes a real, active account the team-map page.
bool isLocationShareAskDue({
  required EmployeeRecord? me,
  required bool askedThisBuild,
}) =>
    me != null &&
    me.uid.isNotEmpty &&
    me.isActive &&
    !me.isTestAccount &&
    !askedThisBuild;

/// The page's version, from the sharing switch and the iOS permission.
LocationShareAskVariant locationShareAskVariant({
  required bool sharing,
  required LocationPermissionResult permission,
}) => switch (permission) {
  LocationPermissionResult.permanentlyDenied ||
  LocationPermissionResult.servicesDisabled =>
    LocationShareAskVariant.openSettings,
  LocationPermissionResult.granted when sharing =>
    LocationShareAskVariant.alreadyOn,
  LocationPermissionResult.granted ||
  LocationPermissionResult.denied => LocationShareAskVariant.turnOn,
};
