import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:scheduling/core/logging/app_logger.dart';

/// Thin wrapper over [FirebaseMessaging] with every call guarded against
/// errors. Device-only, so there are no unit tests for it.
class PushNotificationService {
  PushNotificationService({FirebaseMessaging? messaging, AppLogger? logger})
    : _injectedMessaging = messaging,
      _logger = logger ?? AppLogger();

  final FirebaseMessaging? _injectedMessaging;
  final AppLogger _logger;

  // Resolved lazily, since eager .instance access throws if Firebase isn't
  // initialized yet.
  FirebaseMessaging get _messaging =>
      _injectedMessaging ?? FirebaseMessaging.instance;

  /// Prompts for OS notification permission. Returns true when granted or
  /// provisional.
  Future<bool> requestPermission() async {
    try {
      final settings = await _messaging.requestPermission();
      return isGranted(settings.authorizationStatus);
    } catch (e, st) {
      _logger.warn('PUSH requestPermission failed', e, st);
      return false;
    }
  }

  /// OS-level authorization status without prompting. Defaults to
  /// notDetermined on failure.
  Future<AuthorizationStatus> authorizationStatus() async {
    try {
      final settings = await _messaging.getNotificationSettings();
      return settings.authorizationStatus;
    } catch (e, st) {
      _logger.warn('PUSH getNotificationSettings failed', e, st);
      return AuthorizationStatus.notDetermined;
    }
  }

  /// True when notifications are authorized (or provisional).
  static bool isGranted(AuthorizationStatus status) =>
      status == AuthorizationStatus.authorized ||
      status == AuthorizationStatus.provisional;

  /// Opens the OS Settings page to re-enable notifications after the one-time
  /// prompt.
  Future<bool> openSystemSettings() async {
    try {
      return await openAppSettings();
    } catch (e, st) {
      _logger.warn('PUSH openAppSettings failed', e, st);
      return false;
    }
  }

  /// Enables iOS foreground banners — without this, foreground notifications
  /// show nothing on iOS.
  Future<void> configureForegroundPresentation() async {
    try {
      await _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (e, st) {
      _logger.warn('PUSH foreground options failed', e, st);
    }
  }

  /// Device FCM token, or null on failure. On iOS, retries briefly if the
  /// APNS token is momentarily null.
  Future<String?> currentToken() async {
    try {
      if (Platform.isIOS) {
        var apns = await _messaging.getAPNSToken();
        if (apns == null) {
          await Future<void>.delayed(const Duration(seconds: 2));
          apns = await _messaging.getAPNSToken();
        }
        if (apns == null) {
          _logger.warn('PUSH no APNS token yet');
          return null;
        }
      }
      // ignore: deprecated_member_use — the backend sends to FCM tokens; register() yields a FID.
      return await _messaging.getToken();
    } catch (e, st) {
      _logger.warn('PUSH getToken failed', e, st);
      return null;
    }
  }

  /// Emits a fresh token whenever FCM rotates it.
  // ignore: deprecated_member_use — see getToken; onRegistered emits a FID.
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;

  /// The message that launched the app from a terminated state (tap), if any.
  Future<RemoteMessage?> initialMessage() async {
    try {
      return await _messaging.getInitialMessage();
    } catch (e, st) {
      _logger.warn('PUSH getInitialMessage failed', e, st);
      return null;
    }
  }

  /// Fired when a background (not terminated) notification is tapped.
  Stream<RemoteMessage> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp;

  /// Invalidates the device token (used on sign-out).
  Future<void> deleteToken() async {
    try {
      // ignore: deprecated_member_use — see getToken; unregister() drops a FID.
      await _messaging.deleteToken();
    } catch (e, st) {
      _logger.warn('PUSH deleteToken failed', e, st);
    }
  }
}
