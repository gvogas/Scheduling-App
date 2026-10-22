import 'package:flutter/foundation.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

/// The last answer the callable gave, and whether it may be filtered further
/// instead of asking again.
///
/// Phone matching is a SUBSTRING test, so the candidate set only ever shrinks
/// as digits land: anything matching ten digits already matched the first
/// seven. That is what lets one query serve a whole number — but only when the
/// answer was COMPLETE. At the result cap the client being looked for may never
/// have come back, and narrowing would hide it with nothing logged.
@immutable
class ClientSearchWindow {
  const ClientSearchWindow({
    required this.digits,
    required this.results,
    required this.truncated,
  });

  static const ClientSearchWindow empty = ClientSearchWindow(
    digits: '',
    results: [],
    truncated: false,
  );

  final String digits;
  final List<ClientRecord> results;
  final bool truncated;

  bool get isEmpty => digits.isEmpty;

  bool canNarrowTo(String nextDigits) =>
      !isEmpty &&
      !truncated &&
      nextDigits.length > digits.length &&
      nextDigits.startsWith(digits);

  ClientSearchWindow narrowTo(String nextDigits) => ClientSearchWindow(
    digits: nextDigits,
    truncated: false,
    results: [
      for (final client in results)
        if (ClientSearchPolicy.index(
          client,
        ).phoneDigits.any((number) => number.contains(nextDigits)))
          client,
    ],
  );
}
