
import 'package:scheduling/core/analytics/analytics_events.dart';

/// Longest string value that may reach Firebase — a backstop, not the design.
const int kAnalyticsMaxValueLength = 36;

/// Buckets a raw count so a rare exact value can't single a person out.
int bucketCount(int value) {
  if (value <= 0) return 0;
  if (value <= 5) return value;
  if (value <= 10) return 10;
  if (value <= 25) return 25;
  if (value <= 50) return 50;
  if (value <= 100) return 100;
  return 500;
}

/// Buckets a typed query's LENGTH; the query itself is never sent.
int bucketQueryLength(int length) {
  if (length <= 0) return 0;
  if (length <= 2) return 2;
  if (length <= 5) return 5;
  if (length <= 10) return 10;
  return 20;
}

/// Drops undeclared keys (asserting in debug), narrows types, caps strings.
Map<String, Object> sanitizeAnalyticsParams(Map<String, Object?>? params) {
  if (params == null || params.isEmpty) return const {};
  final sanitized = <String, Object>{};
  for (final entry in params.entries) {
    final key = entry.key;
    if (!AnalyticsParams.allParams.contains(key)) {
      assert(
        false,
        'Analytics parameter "$key" is not in AnalyticsParams.allParams. '
        'Declare it there first — the allowlist is what keeps PII off the wire.',
      );
      continue;
    }
    final value = _sanitizeValue(entry.value);
    if (value != null) sanitized[key] = value;
  }
  return sanitized;
}

Object? _sanitizeValue(Object? value) {
  return switch (value) {
    null => null,
    // Firebase has no bool parameter type; 1/0 is the documented shape.
    final bool b => b ? 1 : 0,
    // NaN/Infinity serialize as null natively, dropping the parameter.
    final double d when !d.isFinite => null,
    final num n => n,
    final String s => _sanitizeString(s),
    _ => null,
  };
}

String? _sanitizeString(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length <= kAnalyticsMaxValueLength
      ? trimmed
      : trimmed.substring(0, kAnalyticsMaxValueLength);
}

/// Sanitizes a user-property value; the caller checks the NAME.
String? sanitizeUserPropertyValue(String? value) =>
    value == null ? null : _sanitizeString(value);

/// True when [name] is a declared, well-formed user property.
bool isKnownUserProperty(String name) =>
    AnalyticsUserProperties.allProperties.contains(name) &&
    AnalyticsNames.isValidUserProperty(name);

/// True when [name] is a declared, well-formed event.
bool isKnownEvent(String name) =>
    AnalyticsEvents.allEvents.contains(name) &&
    AnalyticsNames.isValidEvent(name);
