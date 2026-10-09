import 'package:scheduling/core/utils/firestore_parsing.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

const int kSearchTokenQueryLimit = 10;
const int kSearchTokenFieldLimit = 240;

/// Hand-mirrored by `functions/search_tokens.js`; change both together.
List<String> searchQueryTokens(String query) {
  final text = ClientSearchPolicy.normalize(query);
  final digits = ClientSearchPolicy.digitsOnly(query);
  final tokens = <String>{};
  for (final word in text.split(' ')) {
    if (word.isEmpty) continue;
    tokens.add('t:$word');
  }
  if (digits.isNotEmpty) tokens.add('p:$digits');
  return tokens.take(kSearchTokenQueryLimit).toList();
}

/// Two ordering rules carry the whole design, because [limit] really does
/// bite: each word emits its WHOLE token before any of its prefixes, so an
/// exact-word query survives truncation; and the text and phone runs are
/// INTERLEAVED, so a long client name can never push the phone tokens past the
/// cap.
List<String> searchIndexTokens({
  required Iterable<String> texts,
  required Iterable<String> phones,
  int limit = kSearchTokenFieldLimit,
}) {
  final textTokens = <String>{};
  for (final value in texts) {
    for (final word in ClientSearchPolicy.normalize(value).split(' ')) {
      if (word.isEmpty) continue;
      final max = word.length.clamp(1, 24);
      textTokens.add('t:${word.substring(0, max)}');
      for (var i = 1; i < max; i++) {
        textTokens.add('t:${word.substring(0, i)}');
      }
    }
  }
  final phoneTokens = <String>{};
  for (final phone in phones) {
    final digits = ClientSearchPolicy.digitsOnly(phone);
    if (digits.length < 3) continue;
    phoneTokens.add('p:${digits.substring(0, digits.length.clamp(3, 12))}');
    for (var start = 0; start < digits.length; start++) {
      final remaining = digits.length - start;
      if (remaining < 3) break;
      final max = remaining.clamp(3, 12);
      for (var len = 3; len <= max; len++) {
        phoneTokens.add('p:${digits.substring(start, start + len)}');
      }
    }
  }
  final text = textTokens.toList();
  final phone = phoneTokens.toList();
  final out = <String>[];
  for (var i = 0; i < text.length || i < phone.length; i++) {
    if (out.length >= limit) break;
    if (i < text.length) out.add(text[i]);
    if (out.length < limit && i < phone.length) out.add(phone[i]);
  }
  return out;
}

/// Hand-mirrored by `appointmentHistoryScopes` in `functions/search_tokens.js`.
List<String> appointmentHistoryScopes(Map<String, dynamic> data) {
  final tokens = searchIndexTokens(
    texts: [
      (data['clientName'] ?? '').toString(),
      ...firestoreStringList(data['employeeNames']),
    ],
    phones: [(data['clientPhone'] ?? '').toString()],
  );
  return [for (final token in tokens) 'all:$token'];
}
