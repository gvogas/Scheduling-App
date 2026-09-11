
import 'package:scheduling/core/analytics/analytics_events.dart';

/// Longest string value that may reach Firebase. Every legitimate value this
/// app sends is a short slug from [AnalyticsSources] and friends, so anything
/// near this bound is already a bug — the cap is the backstop, not the design.
const int kAnalyticsMaxValueLength = 36;

/// Buckets a raw count so a rare exact value can't single a person out.
///
/// A `result_count` of 1 is fine; a `result_count` of 4173 describes exactly
/// one business on exactly one day. Buckets keep the distribution answerable
/// ("how many results does a typical search return?") without the long tail
/// that makes a row identifying.
int bucketCount(int value) {
  if (value <= 0) return 0;
  if (value <= 5) return value;
  if (value <= 10) return 10;
  if (value <= 25) return 25;
  if (value <= 50) return 50;
  if (value <= 100) return 100;
  return 500;
}

/// Buckets a typed query's LENGTH. The query itself is never sent — a client
/// search is somebody's phone number or surname by definition.
int bucketQueryLength(int length) {
  if (length <= 0) return 0;
  if (length <= 2) return 2;
  if (length <= 5) return 5;
  if (length <= 10) return 10;
  return 20;
}

/// Sanitizes an outgoing analytics parameter map.
///
/// Three rules, in order:
///
/// 1. **Allowlist.** A key absent from [AnalyticsParams.allParams] is DROPPED.
///    This is the load-bearing half. This app holds client phone numbers,
///    street addresses, job notes and employee emails, and the way those leak
///    is never a deliberate decision — it is one call site passing a
///    convenient `'client_name': record.name` that nobody reads again. An
///    allowlist means a new parameter cannot ship without someone adding it to
///    that set, which is the moment the question "is this safe to transmit?"
///    actually gets asked.
/// 2. **Type narrowing.** Only `num`, `bool` and `String` survive; a `bool`
///    becomes 1/0 because Firebase has no boolean parameter type, and anything
///    else (a record, a list, a `DateTime`) is dropped rather than
///    `toString()`-ed — `toString()` on a domain model is exactly how a client
///    name reaches a wire.
/// 3. **Value capping.** A surviving string is trimmed and cut to
///    [kAnalyticsMaxValueLength].
///
/// In debug builds a dropped key ASSERTS, so a bad call site fails loudly for
/// the developer who wrote it instead of silently under-reporting in
/// production.
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
    // NaN/Infinity serialize as null on the native side, taking the whole
    // parameter with them.
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

/// Sanitizes a user-property value. Same narrowing as a parameter value, minus
/// the allowlist — the NAME is checked by the caller against
/// [AnalyticsUserProperties.allProperties].
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
