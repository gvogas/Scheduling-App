import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:scheduling/core/logging/app_logger.dart';

/// Outcome of a location-permission request.
enum LocationPermissionResult {
  granted,
  denied,
  permanentlyDenied,
  servicesDisabled,
}

/// Never requests an Always upgrade. A pre-existing Always grant still counts
/// as granted.
class LocationPermissionService {
  LocationPermissionService({
    Future<bool> Function()? isServiceEnabled,
    Future<LocationPermission> Function()? checkPermission,
    Future<LocationPermission> Function()? requestPermission,
    Future<bool> Function()? openAppSettings,
    AppLogger? logger,
  }) : _isServiceEnabled =
           isServiceEnabled ?? Geolocator.isLocationServiceEnabled,
       _checkPermission = checkPermission ?? Geolocator.checkPermission,
       _requestPermission = requestPermission ?? Geolocator.requestPermission,
       _openAppSettings = openAppSettings ?? Geolocator.openAppSettings,
       _logger = logger ?? AppLogger();

  final Future<bool> Function() _isServiceEnabled;
  final Future<LocationPermission> Function() _checkPermission;
  final Future<LocationPermission> Function() _requestPermission;
  final Future<bool> Function() _openAppSettings;
  final AppLogger _logger;

  Future<LocationPermissionResult> ensureLocation() async {
    try {
      if (!await _isServiceEnabled()) {
        return LocationPermissionResult.servicesDisabled;
      }
      var permission = await _checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await _requestPermission();
      }
      return _resultOf(permission);
    } catch (e, st) {
      _logger.warn('PERM-LOCATION ensureLocation failed', e, st);
      return LocationPermissionResult.denied;
    }
  }

  /// The permission as it stands, without ever prompting.
  Future<LocationPermissionResult> currentStatus() async {
    try {
      if (!await _isServiceEnabled()) {
        return LocationPermissionResult.servicesDisabled;
      }
      return _resultOf(await _checkPermission());
    } catch (e, st) {
      _logger.warn('PERM-LOCATION currentStatus failed', e, st);
      return LocationPermissionResult.denied;
    }
  }

  /// Opens this app's page in iOS Settings, the only place a refusal is undone.
  Future<bool> openSettings() async {
    try {
      return await _openAppSettings();
    } catch (e, st) {
      _logger.warn('PERM-LOCATION openSettings failed', e, st);
      return false;
    }
  }

  static LocationPermissionResult _resultOf(LocationPermission permission) =>
      switch (permission) {
        LocationPermission.always ||
        LocationPermission.whileInUse => LocationPermissionResult.granted,
        LocationPermission.deniedForever =>
          LocationPermissionResult.permanentlyDenied,
        LocationPermission.denied ||
        LocationPermission.unableToDetermine => LocationPermissionResult.denied,
      };
}

final locationPermissionServiceProvider = Provider<LocationPermissionService>(
  (ref) => LocationPermissionService(),
);

/// The location permission as it stands, read without prompting.
final locationPermissionStatusProvider =
    FutureProvider.autoDispose<LocationPermissionResult>(
      (ref) => ref.watch(locationPermissionServiceProvider).currentStatus(),
    );
