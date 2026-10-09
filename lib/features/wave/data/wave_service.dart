import 'package:cloud_functions/cloud_functions.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/wave/domain/models/wave_connection.dart';
import 'package:scheduling/features/wave/domain/wave_error_mapper.dart';
import 'package:scheduling/features/wave/domain/wave_failure.dart';

/// How long the app waits on a "Sync with Wave" run before reporting failure.
///
/// Hand-mirrored by `SYNC_PUSH_BUDGET_MS` in `functions/wave/sync_run.js`,
/// which is sized to leave most of this window to the import half.
const int kWaveSyncTimeoutSeconds = 120;

/// The deadline on the short Wave callables — connecting and the connection
/// read. The sync and the dead-letter requeue keep the longer budget above.
const Duration _callableTimeout = Duration(seconds: 20);

class WaveService {
  WaveService({FirebaseFunctions? functions, AppLogger? logger})
    : _functions =
          functions ?? FirebaseFunctions.instanceFor(region: 'us-central1'),
      _logger = logger ?? AppLogger();

  final FirebaseFunctions _functions;
  final AppLogger _logger;

  /// Firebase callables can return `Map<dynamic, dynamic>` on Android.
  Map<String, dynamic> _mapResult(HttpsCallableResult<dynamic> result) =>
      (result.data as Map?)?.cast<String, dynamic>() ?? const {};

  /// Connect to Wave; business resolved server-side.
  Future<WaveConnection> bootstrap() async {
    final HttpsCallableResult<dynamic> result;
    try {
      result = await _functions
          .httpsCallable(
            'waveBootstrap',
            options: HttpsCallableOptions(timeout: _callableTimeout),
          )
          .call(<String, dynamic>{});
    } catch (e, st) {
      throw _logFailure('WAVE-BOOT waveBootstrap callable failed', e, st);
    }

    try {
      final data = _mapResult(result);
      return WaveConnection.fromMap(data);
    } catch (e, st) {
      _logger.warn('WAVE-BOOT waveBootstrap response parse failed', e, st);
      throw WaveErrorMapper.map(e);
    }
  }

  /// Read persisted Wave connection; backs "Connected to X" status display.
  Future<WaveConnection?> getConnection() async {
    final HttpsCallableResult<dynamic> result;
    try {
      result = await _functions
          .httpsCallable(
            'waveGetConnection',
            options: HttpsCallableOptions(timeout: _callableTimeout),
          )
          .call(<String, dynamic>{});
    } catch (e, st) {
      throw _logFailure('WAVE-CONN waveGetConnection callable failed', e, st);
    }

    try {
      final data = _mapResult(result);
      if (data['connected'] != true) return null;
      return WaveConnection.fromMap(data);
    } catch (e, st) {
      _logger.warn('WAVE-CONN waveGetConnection response parse failed', e, st);
      throw WaveErrorMapper.map(e);
    }
  }

  /// Runs a two-way sync: pending app edits are pushed to Wave first, then
  /// Wave customers are pulled back into `clients`.
  ///
  /// Keeps the `waveImportCustomers` name: never rename in place; every build calls it.
  ///
  /// A callable cannot be cancelled, so this timeout is not a limit on the
  /// server — it is the point at which the admin is told the sync failed
  /// while it keeps running. `SYNC_PUSH_BUDGET_MS` in `wave/sync_run.js` is
  /// sized against it (hand-mirrored; each carries a pointer to the other):
  /// the push takes a small slice and the import gets the rest.
  Future<WaveSyncSummary> syncCustomers() async {
    final HttpsCallableResult<dynamic> result;
    try {
      result = await _functions
          .httpsCallable(
            'waveImportCustomers',
            options: HttpsCallableOptions(
              timeout: const Duration(seconds: kWaveSyncTimeoutSeconds),
            ),
          )
          .call(<String, dynamic>{});
    } catch (e, st) {
      throw _logFailure('WAVE-CUST waveImportCustomers callable failed', e, st);
    }

    try {
      final data = _mapResult(result);
      return WaveSyncSummary.fromMap(data);
    } catch (e, st) {
      _logger.warn(
        'WAVE-CUST waveImportCustomers response parse failed',
        e,
        st,
      );
      throw WaveErrorMapper.map(e);
    }
  }

  /// Returns dead-lettered outbox jobs to the queue and pushes them.
  ///
  /// A dead-lettered job is terminal: nothing retries it, so that client's
  /// data diverges from Wave permanently. This is the only way back, and it is
  /// deliberately a manual action — a job that died on a validation error will
  /// die again, so an automatic retry would spin on it forever.
  ///
  /// Takes the sync timeout rather than the 20 s the other admin reads use:
  /// the callable requeues AND then drains, so it is bounded by the same push
  /// budget "Sync with Wave" is.
  Future<WaveRetryResult> retryFailedJobs() async {
    final HttpsCallableResult<dynamic> result;
    try {
      result = await _functions
          .httpsCallable(
            'waveRetryFailedJobs',
            options: HttpsCallableOptions(
              timeout: const Duration(seconds: kWaveSyncTimeoutSeconds),
            ),
          )
          .call(<String, dynamic>{});
    } catch (e, st) {
      throw _logFailure(
        'WAVE-RETRY waveRetryFailedJobs callable failed',
        e,
        st,
      );
    }

    try {
      final data = _mapResult(result);
      return WaveRetryResult.fromMap(data);
    } catch (e, st) {
      _logger.warn(
        'WAVE-RETRY waveRetryFailedJobs response parse failed',
        e,
        st,
      );
      throw WaveErrorMapper.map(e);
    }
  }

  /// Maps [e]; a server-side pause is an operator state, so only a breadcrumb.
  WaveFailure _logFailure(String label, Object e, StackTrace st) {
    final failure = WaveErrorMapper.map(e);
    if (failure is WavePaused) {
      _logger.breadcrumb('$label (feature paused)');
    } else {
      _logger.warn(label, e, st);
    }
    return failure;
  }
}
