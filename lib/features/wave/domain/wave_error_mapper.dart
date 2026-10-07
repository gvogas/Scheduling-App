import 'package:cloud_functions/cloud_functions.dart';

import 'package:scheduling/features/wave/domain/wave_failure.dart';

class WaveErrorMapper {
  const WaveErrorMapper._();

  static WaveFailure map(Object error) {
    if (error is WaveFailure) return error;

    if (error is FirebaseFunctionsException) {
      return _fromException(error);
    }

    return const WaveUnknown();
  }

  static WaveFailure _fromException(FirebaseFunctionsException e) {
    // Match on message first for wave/* semantic codes, then fall back to code.
    final msg = e.message ?? '';

    // `assertFeatureEnabled` (functions/feature_flags.js) refuses this way.
    if (msg == 'feature-disabled') return const WavePaused();

    if (msg == 'wave/token-invalid') return const WaveAuthInvalid();

    if (msg == 'wave/rate-limited' || e.code == 'resource-exhausted') {
      return const WaveRateLimited();
    }

    if (msg == 'wave/network' || e.code == 'unavailable') {
      return const WaveNetwork();
    }

    if (msg == 'wave/validation' || e.code == 'invalid-argument') {
      return const WaveValidation();
    }

    // `wave/not-connected` is the retired spelling of the same state; a
    // backend older than the canonicalization still sends it.
    if (msg == 'wave/not-bootstrapped' || msg == 'wave/not-connected') {
      return const WaveValidation(reason: 'notConnected');
    }

    // Ambiguous — multiple businesses are linked to this token and there's no
    // picker yet, so we're honest about it rather than guessing.
    if (msg == 'wave/business-ambiguous') {
      return const WaveValidation(reason: 'businessAmbiguous');
    }

    if (msg == 'wave/business-not-found') {
      return const WaveValidation();
    }

    if (msg == 'wave/not-admin') return const WaveUnknown();

    if (msg == 'wave/unknown' || e.code == 'internal') {
      return const WaveUnknown();
    }

    return const WaveUnknown();
  }
}
