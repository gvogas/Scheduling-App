import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/app/app_sync_listeners.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/launchers/phone_call_launcher.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/platform/ios_platform.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/siri/application/schedule_snapshot_provider.dart';
import 'package:scheduling/features/siri/application/schedule_snapshot_service.dart';

/// The CarPlay scene's channel.
const carPlayChannelName = 'net.vogas.scheduling/carplay';

/// Answers the CarPlay scene's live-app requests; the car renders without it.
class CarPlayBridge {
  CarPlayBridge(
    this._ref, {
    bool Function()? isIosPlatform,
    MethodChannel channel = const MethodChannel(carPlayChannelName),
  }) : _isIosPlatform = isIosPlatform ?? defaultIsIosPlatform,
       _channel = channel;

  final Ref _ref;
  final bool Function() _isIosPlatform;
  final MethodChannel _channel;

  bool _listening = false;

  static const _carPlayConnected = 'carPlayConnected';
  static const _setAppointmentStatus = 'setAppointmentStatus';
  static const _dialableNumberFor = 'dialableNumberFor';
  static const _snapshotChanged = 'snapshotChanged';

  void start() {
    if (!_isIosPlatform()) return;
    _channel.setMethodCallHandler(_handleCall);
    _listening = true;
  }

  void dispose() {
    if (!_listening) return;
    _channel.setMethodCallHandler(null);
    _listening = false;
  }

  /// Dart → Swift: the App Group was rewritten, re-read it and rebuild.
  Future<void> notifySnapshotChanged() async {
    if (!_isIosPlatform()) return;
    await _channel.invokeMethod<void>(_snapshotChanged);
  }

  Future<Object?> _handleCall(MethodCall call) async {
    // Resolved before the first await: `ref.read` after one can throw.
    final logger = _ref.read(loggerProvider);
    try {
      switch (call.method) {
        case _carPlayConnected:
          await _refreshSnapshot();
          return null;
        case _setAppointmentStatus:
          return await _writeStatus(call.arguments, logger);
        case _dialableNumberFor:
          return await _dialableNumber(call.arguments);
      }
    } catch (error, stackTrace) {
      logger.warn('CARPLAY ${call.method} failed', error, stackTrace);
      // The status write answers a bool; the other two answer null.
      return call.method == _setAppointmentStatus ? false : null;
    }
    throw MissingPluginException('${call.method} is not implemented');
  }

  /// Every connect refreshes, so the car never renders a stale snapshot.
  Future<void> _refreshSnapshot() async {
    final snapshot = _ref.read(scheduleSnapshotProvider);
    final service = _ref.read(scheduleSnapshotServiceProvider);
    if (AppSyncListeners.isUnsettled(snapshot)) return;
    await service.apply(snapshot.value);
  }

  /// Fails fast offline: a pending write would never answer the channel.
  Future<bool> _writeStatus(Object? arguments, AppLogger logger) async {
    final args = _argumentsOf(arguments);
    final id = (args['id'] as String?)?.trim() ?? '';
    final status = (args['status'] as String?)?.trim() ?? '';
    if (id.isEmpty || status.isEmpty) return false;
    if (_ref.read(isOfflineProvider)) {
      logger.warn('CARPLAY setAppointmentStatus blocked while offline');
      return false;
    }
    final repository = _ref.read(appointmentsRepositoryProvider);
    await repository.updateAppointmentStatus(id: id, status: status);
    return true;
  }

  /// The FINISHED `tel:` URI, so the stripping rule never forks into Swift.
  Future<String?> _dialableNumber(Object? arguments) async {
    final id = (_argumentsOf(arguments)['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;
    final record = await _ref
        .read(appointmentsRepositoryProvider)
        .getAppointmentById(id);
    final phone = record?.clientPhone.trim() ?? '';
    return phone.isEmpty ? null : dialableUri(phone).toString();
  }

  /// Loosely cast — the platform hands arguments back as `Map<Object?, Object?>`.
  Map<String, dynamic> _argumentsOf(Object? arguments) =>
      (arguments as Map?)?.cast<String, dynamic>() ?? const {};
}

final carPlayBridgeProvider = Provider<CarPlayBridge>(CarPlayBridge.new);
