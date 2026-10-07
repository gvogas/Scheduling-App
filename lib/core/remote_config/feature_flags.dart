import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

/// Kill switches; keys and defaults mirror `functions/feature_flags_policy.js`.
@immutable
class FeatureFlags {
  const FeatureFlags({
    required this.addressAutocomplete,
    required this.presence,
    required this.liveActivities,
    required this.waveSync,
    required this.minSupportedBuild,
  });

  /// A static value (no remote, no default) takes the code default, not false.
  factory FeatureFlags.fromValues(Map<String, RemoteConfigValue> values) {
    bool readBool(String key, {required bool fallback}) {
      final v = values[key];
      if (v == null || v.source == ValueSource.valueStatic) return fallback;
      return parseBool(v.asString(), fallback: fallback);
    }

    int readInt(String key, int fallback) {
      final v = values[key];
      if (v == null || v.source == ValueSource.valueStatic) return fallback;
      return parseInt(v.asString(), fallback: fallback);
    }

    return FeatureFlags(
      addressAutocomplete: readBool(
        _addressAutocomplete,
        fallback: defaults.addressAutocomplete,
      ),
      presence: readBool(_presence, fallback: defaults.presence),
      liveActivities: readBool(
        _liveActivities,
        fallback: defaults.liveActivities,
      ),
      waveSync: readBool(_waveSync, fallback: defaults.waveSync),
      minSupportedBuild: readInt(
        _minSupportedBuild,
        defaults.minSupportedBuild,
      ),
    );
  }

  /// Only `true`/`false` (any case, trimmed) count; anything else fails OPEN to [fallback].
  static bool parseBool(String raw, {required bool fallback}) =>
      switch (raw.trim().toLowerCase()) {
        'true' => true,
        'false' => false,
        _ => fallback,
      };

  /// Only a plain (optionally signed) integer counts; anything else takes [fallback].
  static int parseInt(String raw, {required int fallback}) {
    final trimmed = raw.trim();
    return _integer.hasMatch(trimmed)
        ? int.tryParse(trimmed) ?? fallback
        : fallback;
  }

  static final _integer = RegExp(r'^[+-]?\d+$');

  static const defaults = FeatureFlags(
    addressAutocomplete: true,
    presence: true,
    liveActivities: true,
    waveSync: true,
    minSupportedBuild: 0,
  );

  static const _addressAutocomplete = 'feature_address_autocomplete';
  static const _presence = 'feature_presence';
  static const _liveActivities = 'feature_live_activities';
  static const _waveSync = 'feature_wave_sync';
  static const _minSupportedBuild = 'min_supported_build';

  static const keys = [
    _addressAutocomplete,
    _presence,
    _liveActivities,
    _waveSync,
    _minSupportedBuild,
  ];

  final bool addressAutocomplete;
  final bool presence;
  final bool liveActivities;
  final bool waveSync;
  final int minSupportedBuild;

  Map<String, Object> toRemoteConfigDefaults() => {
    _addressAutocomplete: addressAutocomplete,
    _presence: presence,
    _liveActivities: liveActivities,
    _waveSync: waveSync,
    _minSupportedBuild: minSupportedBuild,
  };

  @override
  bool operator ==(Object other) =>
      other is FeatureFlags &&
      other.addressAutocomplete == addressAutocomplete &&
      other.presence == presence &&
      other.liveActivities == liveActivities &&
      other.waveSync == waveSync &&
      other.minSupportedBuild == minSupportedBuild;

  @override
  int get hashCode => Object.hash(
    addressAutocomplete,
    presence,
    liveActivities,
    waveSync,
    minSupportedBuild,
  );

  @override
  String toString() =>
      'FeatureFlags(addr: $addressAutocomplete, presence: $presence, '
      'liveAct: $liveActivities, wave: $waveSync, minBuild: $minSupportedBuild)';
}
