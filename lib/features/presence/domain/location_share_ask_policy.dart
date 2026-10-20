import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

/// Which version of the team-map page a person gets.
enum LocationShareAskVariant { turnOn, consented, openSettings, alreadyOn }

/// How long a setup consent still counts as "just given" on the first calendar.
const kLocationConsentFreshFor = Duration(hours: 1);

/// Whether an account may get the team-map page; per build, see the store.
bool isLocationShareAskDue({required EmployeeRecord? me}) =>
    me != null && me.uid.isNotEmpty && me.isActive && !me.isTestAccount;

/// True when setup's consent sentence was ticked within [kLocationConsentFreshFor].
bool isLocationConsentFresh({
  required DateTime? consentAt,
  required DateTime now,
}) =>
    consentAt != null &&
    !consentAt.isAfter(now.add(kLocationConsentFreshFor)) &&
    now.difference(consentAt) <= kLocationConsentFreshFor;

/// The page's version, from the sharing switch, the iOS permission and a
/// consent just given in setup, which turns the question into its iOS step.
LocationShareAskVariant locationShareAskVariant({
  required bool sharing,
  required LocationPermissionResult permission,
  bool consentFresh = false,
}) => switch (permission) {
  LocationPermissionResult.permanentlyDenied ||
  LocationPermissionResult.servicesDisabled =>
    LocationShareAskVariant.openSettings,
  LocationPermissionResult.granted when sharing =>
    LocationShareAskVariant.alreadyOn,
  LocationPermissionResult.granted ||
  LocationPermissionResult.denied when consentFresh =>
    LocationShareAskVariant.consented,
  LocationPermissionResult.granted ||
  LocationPermissionResult.denied => LocationShareAskVariant.turnOn,
};
