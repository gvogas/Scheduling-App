import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

/// Which version of the team-map page a person gets.
enum LocationShareAskVariant { turnOn, openSettings, alreadyOn }

/// Whether an account may get the team-map page; per build, see the store.
bool isLocationShareAskDue({required EmployeeRecord? me}) =>
    me != null && me.uid.isNotEmpty && me.isActive && !me.isTestAccount;

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
