import 'package:scheduling/core/utils/firestore_parsing.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';

/// A pre-normalized searchable projection of a client.
///
/// `phoneDigits` is ONE ENTRY PER NUMBER, never a concatenation. Joining them
/// let a query straddle the seam between two numbers and match a number nobody
/// has, and it made the exact-match tier unreachable for any client with both a
/// phone and a mobile.
typedef ClientSearchEntry = ({
  ClientRecord client,
  String text,
  List<String> phoneDigits,
});

class ClientSearchPolicy {
  const ClientSearchPolicy._();

  static const int resultDisplayLimit = 25;

  // Compiled once, since digitsOnly runs per row on every keystroke.
  static final _nonDigit = RegExp(r'\D');

  // Kicks in on the first letter or digit — blank or punctuation-only input is
  // ignored so we don't trigger a full collection scan.
  static bool shouldSearch(String query) => normalize(query).isNotEmpty;

  static String cacheKey(String query) => normalize(query);

  /// Lowercase, accent-folded, non-alphanumerics collapsed to single spaces,
  /// trimmed.
  static String normalize(String value) {
    final out = StringBuffer();
    var pendingSpace = false;
    for (var i = 0; i < value.length; i++) {
      final folded = _foldAccent(value.codeUnitAt(i));
      if (folded == null) {
        // Any run of non-alphanumerics becomes at most one space, and a
        // trailing run never emits — that is `replaceAll(...)` + `trim()`.
        pendingSpace = out.isNotEmpty;
        continue;
      }
      if (pendingSpace) {
        out.writeCharCode(0x20);
        pendingSpace = false;
      }
      out.writeCharCode(folded);
    }
    return out.toString();
  }

  /// The lowercased, accent-folded `a-z0-9` code unit for [unit], or null when
  /// it is not alphanumeric at all.
  ///
  /// **Hand-mirrored by `normalize` in `functions/search_tokens.js`, which
  /// spells the SAME table rather than using NFD.** The two are the index and
  /// the query sides of one search: the app writes tokens with this fold and
  /// the server tokenizes the typed query with that one, so a character they
  /// disagree about is a client nobody can find. NFD folds strictly more (every
  /// decomposable letter, so all of Latin Extended-A), which is why the JS side
  /// cannot simply use it. A letter with no entry here is a SEPARATOR on both
  /// sides — æ, ø and ł have no decomposition either, so they already agree.
  static int? _foldAccent(int unit) {
    // ASCII fast path: digits, then upper- and lower-case letters.
    if (unit >= 0x30 && unit <= 0x39) return unit;
    if (unit >= 0x41 && unit <= 0x5A) return unit + 0x20;
    if (unit >= 0x61 && unit <= 0x7A) return unit;

    // Latin-1 accents, upper and lower, folded to their bare letter.
    return switch (unit) {
      >= 0x00C0 && <= 0x00C5 => 0x61, // À-Å
      >= 0x00E0 && <= 0x00E5 => 0x61, // à-å
      0x00C7 || 0x00E7 => 0x63, // Ç ç
      >= 0x00C8 && <= 0x00CB => 0x65, // È-Ë
      >= 0x00E8 && <= 0x00EB => 0x65, // è-ë
      >= 0x00CC && <= 0x00CF => 0x69, // Ì-Ï
      >= 0x00EC && <= 0x00EF => 0x69, // ì-ï
      >= 0x00D2 && <= 0x00D6 => 0x6F, // Ò-Ö
      >= 0x00F2 && <= 0x00F6 => 0x6F, // ò-ö
      >= 0x00D9 && <= 0x00DC => 0x75, // Ù-Ü
      >= 0x00F9 && <= 0x00FC => 0x75, // ù-ü
      0x00D1 || 0x00F1 => 0x6E, // Ñ ñ
      0x00DD || 0x00FD || 0x00FF => 0x79, // Ý ý ÿ
      _ => null,
    };
  }

  static String digitsOnly(String value) => value.replaceAll(_nonDigit, '');

  /// [index] + [entryMatches] in one call, for a caller holding a single client
  /// and no projection.
  static bool matchesClient(ClientRecord client, String query) {
    final q = normalize(query);
    final qDigits = digitsOnly(query);
    if (q.isEmpty && qDigits.isEmpty) return false;
    return entryMatches(index(client), queryText: q, queryDigits: qDigits);
  }

  /// Normalizes one client into a [ClientSearchEntry].
  static ClientSearchEntry index(ClientRecord client) => (
    client: client,
    text: normalize(
      [
        client.name,
        // Legacy pre-Wave-reshape docs kept the business under its own field.
        client.businessName,
        client.firstName,
        client.lastName,
        client.email,
        client.address,
        client.city,
        client.province,
        client.postalCode,
        client.country,
        for (final c in client.contacts) '${c.name} ${c.email}',
      ].join(' '),
    ),
    phoneDigits: [...ownPhoneDigits(client), ...contactPhoneDigits(client)],
  );

  /// A client's OWN numbers, one entry per number.
  ///
  /// Split from the contacts' because the relevance tiers treat them
  /// differently — only these may score an exact or prefix hit — and because
  /// joining them let a query straddle the seam and match a number nobody has.
  static List<String> ownPhoneDigits(ClientRecord client) =>
      _digitsEach([client.phone, client.mobile]);

  /// The additional contacts' numbers, one entry per number.
  static List<String> contactPhoneDigits(ClientRecord client) =>
      _digitsEach([for (final c in client.contacts) c.phone]);

  /// [ownPhoneDigits] against a RAW Firestore map.
  static List<String> rawOwnPhoneDigits(Map<String, dynamic> data) =>
      _digitsEach([data['phone'], data['mobile']]);

  /// [contactPhoneDigits] against a RAW Firestore map.
  static List<String> rawContactPhoneDigits(Map<String, dynamic> data) =>
      _digitsEach([
        for (final c in firestoreList(
          data['contacts'],
        ).whereType<Map<Object?, Object?>>())
          c['phone'],
      ]);

  static List<String> _digitsEach(List<Object?> raw) => [
    for (final value in raw)
      if (digitsOnly('${value ?? ''}') case final digits when digits.isNotEmpty)
        digits,
  ];

  /// The searchable TEXT fields of a raw Firestore client map.
  ///
  /// The one owner of that field list on the raw-map side: [rawMatches] reads
  /// it and so does the `searchTokens` builder that decides what the server can
  /// find at all, so a field added to only one of them is a search that
  /// silently stops matching.
  static List<String> rawTexts(Map<String, dynamic> data) => [
    (data['name'] ?? '').toString(),
    // Legacy pre-Wave-reshape docs kept the business under its own field.
    (data['businessName'] ?? '').toString(),
    (data['firstName'] ?? '').toString(),
    (data['lastName'] ?? '').toString(),
    (data['email'] ?? '').toString(),
    (data['address'] ?? '').toString(),
    (data['city'] ?? '').toString(),
    (data['province'] ?? '').toString(),
    (data['postalCode'] ?? '').toString(),
    (data['country'] ?? '').toString(),
    for (final c in firestoreList(
      data['contacts'],
    ).whereType<Map<Object?, Object?>>())
      '${c['name'] ?? ''} ${c['email'] ?? ''}',
  ];

  /// Every searchable phone number of a raw Firestore client map, already
  /// reduced to digits — the client's own and its contacts'.
  static List<String> rawPhones(Map<String, dynamic> data) => [
    ...rawOwnPhoneDigits(data),
    ...rawContactPhoneDigits(data),
  ];

  /// [entryMatches] against a RAW Firestore map, without building a
  /// [ClientRecord] first.
  static bool rawMatches(
    Map<String, dynamic> data, {
    required String queryText,
    required String queryDigits,
  }) {
    if (queryText.isEmpty && queryDigits.isEmpty) return false;
    if (queryText.isNotEmpty &&
        normalize(rawTexts(data).join(' ')).contains(queryText)) {
      return true;
    }
    return queryDigits.isNotEmpty &&
        rawPhones(data).any((n) => n.contains(queryDigits));
  }

  /// [relevanceScore] for a built record. The raw-map call site in the
  /// repository keeps its own projection; this is the one for callers that
  /// already hold a [ClientRecord], so neither has to re-spell the field list.
  static int scoreRecord(
    ClientRecord client, {
    required String queryText,
    required String queryDigits,
  }) {
    return relevanceScore(
      displayName: normalize(client.displayName),
      personName: normalize('${client.firstName} ${client.lastName}'),
      phoneDigits: ownPhoneDigits(client),
      contactsDigits: contactPhoneDigits(client),
      queryText: queryText,
      queryDigits: queryDigits,
    );
  }

  /// How well a client matches a query — LOWER is better, 0 is exact.
  static int relevanceScore({
    required String displayName,
    required String personName,
    required List<String> phoneDigits,
    required List<String> contactsDigits,
    required String queryText,
    required String queryDigits,
  }) {
    final hasDigits = queryDigits.isNotEmpty;
    final exactDigits = _withoutNanpPrefix(queryDigits);
    if (displayName == queryText ||
        (hasDigits &&
            phoneDigits.any((n) => _withoutNanpPrefix(n) == exactDigits))) {
      return 0;
    }
    if (displayName.startsWith(queryText) || personName.startsWith(queryText)) {
      return 1;
    }
    if (hasDigits &&
        phoneDigits.any((number) => number.startsWith(queryDigits))) {
      return 2;
    }
    if (displayName.contains(queryText) || personName.contains(queryText)) {
      return 3;
    }
    if (hasDigits &&
        [
          ...phoneDigits,
          ...contactsDigits,
        ].any((number) => number.contains(queryDigits))) {
      return 4;
    }
    return 5;
  }

  // One spelling of a NANP number: an 11-digit "1…" equals its 10 digits.
  static String _withoutNanpPrefix(String digits) =>
      digits.length == 11 && digits.startsWith('1')
      ? digits.substring(1)
      : digits;

  /// The cheap half of [matchesClient] — just two substring checks against an
  /// already-normalized entry and query.
  static bool entryMatches(
    ClientSearchEntry entry, {
    required String queryText,
    required String queryDigits,
  }) {
    final matchesText = queryText.isNotEmpty && entry.text.contains(queryText);
    final matchesPhone =
        queryDigits.isNotEmpty &&
        entry.phoneDigits.any((number) => number.contains(queryDigits));
    return matchesText || matchesPhone;
  }
}
