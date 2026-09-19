import 'package:flutter/foundation.dart';
import 'package:scheduling/core/utils/firestore_parsing.dart';

/// One reason Wave will not accept a client, as recorded by the server-side
/// customer contract (`functions/wave/customer_contract.js`).
///
/// The code vocabulary is SERVER-owned, so an unrecognized one parses to
/// [WaveProblemCode.unknown] rather than being dropped — a rule added
/// backend-side must still render something an admin can act on.
enum WaveProblemCode {
  empty,
  tooLong,
  invalidEmail,
  notDialable,
  unknown;

  static WaveProblemCode fromRaw(String? raw) => switch (raw) {
    'EMPTY' => empty,
    'TOO_LONG' => tooLong,
    'INVALID_EMAIL' => invalidEmail,
    'NOT_DIALABLE' => notDialable,
    _ => unknown,
  };
}

/// A single `wave.problems` entry.
///
/// [field] names the CLIENT DOC field an admin edits, never a Wave payload
/// path — it is what lets the UI point at an input.
@immutable
class WaveProblem {
  const WaveProblem({
    required this.field,
    required this.code,
    required this.isBlocking,
    this.length,
    this.cap,
  });

  final String field;
  final WaveProblemCode code;

  /// Whether Wave would REFUSE this client, as opposed to accepting it with
  /// bad data. Only the server decides: an unrecognized severity is not
  /// blocking, because guessing upward strands a client Wave is happy with.
  final bool isBlocking;

  /// `TOO_LONG` detail; null for every other code.
  final int? length;
  final int? cap;

  static WaveProblem? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final field = map['field']?.toString() ?? '';
    if (field.isEmpty) return null;
    final detail = (map['detail'] as Map?)?.cast<String, dynamic>();
    return WaveProblem(
      field: field,
      code: WaveProblemCode.fromRaw(map['code']?.toString()),
      isBlocking: map['severity'] == 'blocking',
      length: firestoreInt(detail?['length']),
      cap: firestoreInt(detail?['cap']),
    );
  }

  static List<WaveProblem> parseList(Object? raw) {
    return firestoreList(
      raw,
    ).map(WaveProblem.fromMap).whereType<WaveProblem>().toList(growable: false);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WaveProblem &&
          other.field == field &&
          other.code == code &&
          other.isBlocking == isBlocking &&
          other.length == length &&
          other.cap == cap;

  @override
  int get hashCode => Object.hash(field, code, isBlocking, length, cap);
}
