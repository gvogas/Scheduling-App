/// Stored/displayed client-name policy mirrored in Cloud Functions.
library;

import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';

class ClientNamePolicy {
  const ClientNamePolicy._();

  static final _nonDigit = RegExp(r'\D');

  /// Loose phone candidate; [_matchPhone] validates the digits.
  static final _candidate = RegExp(r'\+?\d[\d\s().\-]{7,}\d');
  // Anything outside a digit or a phone separator — a letter, a '+', a '#' —
  // means the field is not a bare number.
  static final _nonPhoneChar = RegExp(r'[^\d\s().\-]');
  static const int _localDigits = 7;
  static const int _nanpDigits = 10;
  static const int _maxDialableDigits = 15;

  /// Digit counts the whole-field branch accepts: a 7-digit local number, or a
  /// full 10 up to the international ceiling. 8 and 9 are neither, which is
  /// where a business named `3101-5696` lands.
  static bool _isDialableDigitCount(int count) =>
      count == _localDigits ||
      (count >= _nanpDigits && count <= _maxDialableDigits);

  /// Trailing phone candidate matched against the doc's own number.
  static final _trailingPhone = RegExp(
    r'[\s,;:\-–—·|]*(\+?\d[\d\s().+\-]{5,}\d)\s*$',
  );

  /// Separator runs at either edge.
  static final _edgeSeparators = RegExp(r'^[\s,;:\-–—·|]+|[\s,;:\-–—·|]+$');

  /// Phone-wrapper seams left after lifting a number out.
  static final _openSeam = RegExp(r'[\s(]+$');
  static final _closeSeam = RegExp(r'^[\s)]+');

  /// Comparable phone digits, with NANP country code removed.
  static String _digits(String value) {
    final digits = value.replaceAll(_nonDigit, '');
    if (digits.length == 11 && digits.startsWith('1')) {
      return digits.substring(1);
    }
    return digits;
  }

  static String _trimSeparators(String value) =>
      value.replaceAll(_edgeSeparators, '').trim();

  /// Removes this client's own trailing phone number from [name].
  static String stripPhone(
    String name, {
    String phone = '',
    String mobile = '',
  }) {
    final base = name.trim();
    if (base.isEmpty) return '';

    // Exact suffix preserves app-written names.
    for (final candidate in [phone.trim(), mobile.trim()]) {
      if (candidate.isEmpty) continue;
      if (base.endsWith(candidate)) {
        return _trimSeparators(
          base.substring(0, base.length - candidate.length),
        );
      }
    }

    // Digit matching catches legacy formatting differences.
    final wanted = <String>{
      for (final candidate in [phone, mobile])
        if (_digits(candidate).isNotEmpty) _digits(candidate),
    };
    if (wanted.isEmpty) return base;

    final match = _trailingPhone.firstMatch(base);
    if (match == null) return base;
    if (!wanted.contains(_digits(match.group(1)!))) return base;
    return _trimSeparators(base.substring(0, match.start));
  }

  /// Composes the persisted Wave customer name.
  static String composeStored({
    required String baseName,
    required String phone,
    String mobile = '',
    ClientType type = ClientType.unset,
    String businessName = '',
  }) {
    final base = stripPhone(baseName, phone: phone, mobile: mobile);
    final number = phone.trim().isNotEmpty ? phone.trim() : mobile.trim();

    // Never compose a business name AWAY: `name` is the Wave identity, and a blank one dead-letters forever.
    if (base.isNotEmpty &&
        (isBusiness(type: type, businessName: businessName) ||
            looksLikeBusinessName(base))) {
      return base;
    }

    return number.isNotEmpty ? bareNumber(number) : base;
  }

  /// Composes saved name fields without losing a person's typed name.
  static ({String name, String firstName, String lastName}) composeSave({
    required String baseName,
    required String phone,
    String mobile = '',
    String firstName = '',
    String lastName = '',
    ClientType type = ClientType.unset,
    String businessName = '',
  }) {
    final stored = composeStored(
      baseName: baseName,
      phone: phone,
      mobile: mobile,
      type: type,
      businessName: businessName,
    );
    final first = firstName.trim();
    final last = lastName.trim();
    final kept = (name: stored, firstName: first, lastName: last);

    final base = stripPhone(baseName, phone: phone, mobile: mobile);
    if (stored == base || base.isEmpty) return kept;
    if (first.isNotEmpty || last.isNotEmpty) return kept;

    final halves = splitPersonName(base);
    return (
      name: stored,
      firstName: halves.firstName,
      lastName: halves.lastName,
    );
  }

  /// Splits a person's name into first and last halves.
  static ({String firstName, String lastName}) splitPersonName(String name) {
    final parts = name.trim().split(RegExp(r'\s+'))
      ..removeWhere((part) => part.isEmpty);
    if (parts.isEmpty) return (firstName: '', lastName: '');
    if (parts.length == 1) return (firstName: parts.first, lastName: '');
    return (
      firstName: parts.sublist(0, parts.length - 1).join(' '),
      lastName: parts.last,
    );
  }

  /// Company-name tokens checked after accent folding.
  static final _businessToken = RegExp(
    '(^|[^a-z])(inc|ltd|ltee|llc|llp|enr|senc|sencrl|cie|corp|corporation|'
    'company|holdings|group|groupe|services|solutions|technology|'
    'technologies|entreprise|entreprises|immobilier|immeuble|immeubles|'
    'gestion|construction|condo|condos|syndicat|copropriete|residence|'
    r'residences|habitations|logements|appartements)([^a-z]|$)',
  );

  /// Business-name signal after this client's phone is stripped.
  static final _anyDigit = RegExp(r'\d');

  /// Heuristic for imported businesses with no type.
  static bool looksLikeBusinessName(String name) {
    final value = name.trim();
    if (value.isEmpty) return false;
    if (_anyDigit.hasMatch(value)) return true;
    final folded = value
        .toLowerCase()
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll('ê', 'e');
    return _businessToken.hasMatch(folded);
  }

  /// Clean base name for re-saving a stored client.
  static String baseNameFor({
    required String name,
    String phone = '',
    String mobile = '',
    String firstName = '',
    String lastName = '',
    String businessName = '',
  }) {
    final stored = stripPhone(name, phone: phone, mobile: mobile);
    if (stored.isNotEmpty) return stored;

    final composed = [
      firstName.trim(),
      lastName.trim(),
    ].where((half) => half.isNotEmpty).join(' ');
    if (composed.isNotEmpty) return composed;

    return stripPhone(businessName, phone: phone, mobile: mobile);
  }

  /// Whether this client is an organization.
  static bool isBusiness({
    ClientType type = ClientType.unset,
    String businessName = '',
  }) =>
      type == ClientType.commercial ||
      type == ClientType.building ||
      businessName.trim().isNotEmpty;

  /// Display name for every in-app surface.
  static String displayFor({
    required String name,
    // Required so callers cannot forget the type.
    required ClientType type,
    String phone = '',
    String mobile = '',
    String firstName = '',
    String lastName = '',
    String businessName = '',
  }) {
    final base = stripPhone(name, phone: phone, mobile: mobile);
    final composed = [
      firstName.trim(),
      lastName.trim(),
    ].where((half) => half.isNotEmpty).join(' ');

    if (isBusiness(type: type, businessName: businessName)) {
      // Businesses prefer the Wave customer name.
      if (base.isNotEmpty) return base;
      final business = stripPhone(businessName, phone: phone, mobile: mobile);
      if (business.isNotEmpty) return business;
      // Contact person beats a bare phone fallback.
      if (composed.isNotEmpty) return composed;
      return name.trim();
    }

    // businessName is blank on the person branch.
    if (composed.isNotEmpty) return composed;
    if (base.isNotEmpty) return base;
    return name.trim();
  }

  /// Lifts a pasted phone number out of the name field.
  static ({String name, String phone})? liftPhoneFromName({
    required String name,
    required String phone,
  }) {
    if (phone.trim().isNotEmpty) return null;
    final match = _matchPhone(name);
    if (match == null) return null;

    final before = name.substring(0, match.start).replaceAll(_openSeam, '');
    final after = name.substring(match.end).replaceAll(_closeSeam, '');
    final remaining = _trimSeparators('$before $after');
    if (remaining.isEmpty) return (name: name, phone: match.formatted);
    return (name: remaining, phone: match.formatted);
  }

  static ({int start, int end, String formatted})? _matchPhone(String text) {
    // The whole field is one number: seed-from-query. Anything dialable counts,
    // because leaving it in the name is what produced clients with nothing to
    // dial. formatPhoneNumber handles both ends — it formats progressively
    // under ten digits and appends anything past the tenth verbatim.
    final whole = text.trim();
    final wholeDigits = _digits(whole);
    if (!_nonPhoneChar.hasMatch(whole) &&
        _isDialableDigitCount(wholeDigits.length)) {
      final start = text.indexOf(whole);
      return (
        start: start,
        end: start + whole.length,
        formatted: formatPhoneNumber(wholeDigits),
      );
    }
    // A number embedded in a longer name still needs the full ten digits.
    for (final match in _candidate.allMatches(text)) {
      final candidate = match.group(0)!;
      // International numbers stay in the name.
      if (candidate.contains('+')) continue;
      if (_digits(candidate).length != 10) continue;
      return (
        start: match.start,
        end: match.end,
        formatted: formatPhoneNumber(_digits(candidate)),
      );
    }
    return null;
  }
}
