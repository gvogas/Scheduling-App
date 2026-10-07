class AddressParser {
  const AddressParser._();

  // Compiled once: `canonicalToDisplay` runs per row in the clients list
  // builder, and an address that matches none of these falls through all four.
  static final _savedApt = RegExp(
    r'^Apt-?\s*([^\-]+)\s*-\s*(.+)$',
    caseSensitive: false,
  );
  static final _labeledApt = RegExp(
    r'^\s*(?:apt|apartment|unit|suite|ste|#)\s*[-#: ]*\s*([A-Za-z0-9][A-Za-z0-9 /]*)\s*[-,]\s*(.+)$',
    caseSensitive: false,
  );
  static final _dashApt = RegExp(
    r'^\s*([A-Za-z0-9][A-Za-z0-9 /]*)\s*-\s*(\d+.+)$',
  );
  static final _trailingApt = RegExp(
    r'^\s*(.+?)\s+(?:#|apt\.?|apartment|unit|suite|ste\.?)\s*[-#: ]*\s*([A-Za-z0-9][A-Za-z0-9 /]*)\s*(,.*)?$',
    caseSensitive: false,
  );
  static final _leadingHashes = RegExp('^#+');
  // `_localityKey` runs ~6-10x per `streetOnly`, and `streetOnly` runs per row
  // in the clients list builder — a per-call constructor here recompiles each.
  static final _whitespaceRun = RegExp(r'\s+');
  static final _postalCode = RegExp(
    r'\b[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z][ -]?\d[ABCEGHJ-NPRSTV-Z]\d\b',
    caseSensitive: false,
  );
  static final _province = RegExp(
    r'\b(AB|BC|MB|NB|NL|NS|NT|NU|ON|PE|QC|SK|YT)\b',
    caseSensitive: false,
  );
  static final _anyDigit = RegExp(r'\d');
  static final _embeddedAptToken = RegExp(
    r'\s+(#|apt\.?|apartment|unit|suite|ste\.?)\s*[-#: ]*\s*[A-Za-z0-9 /]+',
    caseSensitive: false,
  );

  static AptAddress? splitApt(String rawAddress) {
    final value = rawAddress.trim();
    if (value.isEmpty) return null;

    final saved = _savedApt.firstMatch(value);
    if (saved != null) {
      return AptAddress(
        apt: saved.group(1)!.trim(),
        street: saved.group(2)!.trim(),
      );
    }

    final labeled = _labeledApt.firstMatch(value);
    if (labeled != null) {
      return AptAddress(
        apt: labeled.group(1)!.trim(),
        street: labeled.group(2)!.trim(),
      );
    }

    final dash = _dashApt.firstMatch(value);
    if (dash != null) {
      return AptAddress(
        apt: dash.group(1)!.trim(),
        street: dash.group(2)!.trim(),
      );
    }

    final trailing = _trailingApt.firstMatch(value);
    if (trailing != null) {
      final beforeUnit = trailing.group(1)!.trim();
      final apt = trailing.group(2)!.trim();
      final afterUnit = trailing.group(3)?.trim() ?? '';
      return AptAddress(
        apt: apt,
        street: afterUnit.isEmpty ? beforeUnit : '$beforeUnit$afterUnit',
      );
    }

    return null;
  }

  static String combineAptAndStreet(String street, String apt) {
    final cleanStreet = _stripEmbeddedAptToken(street);
    final cleanApt = apt.trim().replaceAll(_leadingHashes, '');
    if (cleanStreet.isEmpty || cleanApt.isEmpty) return cleanStreet;

    final commaIndex = cleanStreet.indexOf(',');
    if (commaIndex == -1) return '$cleanApt-$cleanStreet';

    final firstLine = cleanStreet.substring(0, commaIndex).trim();
    final rest = cleanStreet.substring(commaIndex);
    return '$cleanApt-$firstLine$rest';
  }

  static String formatForDisplay(String street, String apt) {
    final cleanStreet = _stripEmbeddedAptToken(street);
    final cleanApt = apt.trim().replaceAll(_leadingHashes, '');
    if (cleanStreet.isEmpty || cleanApt.isEmpty) return cleanStreet;

    final commaIndex = cleanStreet.indexOf(',');
    if (commaIndex == -1) return '$cleanStreet #$cleanApt';

    final firstLine = cleanStreet.substring(0, commaIndex).trim();
    final rest = cleanStreet.substring(commaIndex);
    return '$firstLine #$cleanApt$rest';
  }

  static String canonicalToDisplay(String stored) {
    final parts = splitApt(stored);
    if (parts == null) return stored;
    return formatForDisplay(parts.street, parts.apt);
  }

  /// The stored form of a street field plus a separate apt field.
  ///
  /// The explicit [apt] wins over an apt embedded in [street]; when it is blank
  /// the embedded one is kept. Both client save paths resolve their address
  /// through here so the precedence rule has exactly one owner.
  static String canonicalFrom({required String street, required String apt}) {
    final parsed = splitApt(street);
    final resolvedStreet = (parsed?.street ?? street).trim();
    final trimmedApt = apt.trim();
    final resolvedApt = trimmedApt.isNotEmpty
        ? trimmedApt
        : (parsed?.apt ?? '').trim();
    return combineAptAndStreet(
      _withoutRepeatedApt(resolvedStreet, resolvedApt),
      resolvedApt,
    );
  }

  /// Peels any FURTHER `<apt>-` still leading [street] after [splitApt] took
  /// the first one off.
  ///
  /// `splitApt` peels exactly one, so a street that already carried the unit
  /// came back out prefixed again — "210-210-4450 Prom. Paton", three of which
  /// are in prod. It rendered as "210-4450 Prom. Paton #210" (the unit twice)
  /// and, worse, re-saving in the app did NOT repair it: the extra prefix
  /// survived every round trip, so the doc was stuck. This heals one on its
  /// next ordinary save.
  ///
  /// Only an EXACT `<resolvedApt>-` repeat is taken, never a general leading
  /// number, so a civic range keeps whatever `splitApt` left of it.
  static String _withoutRepeatedApt(String street, String apt) {
    if (apt.isEmpty) return street;
    final prefix = '$apt-';
    var value = street;
    while (value.startsWith(prefix) && value.length > prefix.length) {
      value = value.substring(prefix.length).trim();
    }
    return value;
  }

  /// The street line alone — [stored] with any trailing segments that merely
  /// repeat the structured locality fields removed.
  ///
  /// Hand-mirrors `streetFromAddress` (`functions/client_address_utils.js`),
  /// which the Wave push has always needed because `clients/{id}.address`
  /// carries more than a street. It moved out of `wave/mappers.js` when
  /// `client_propagation.js` and the address backfill became callers too, so
  /// the rule now has three readers rather than one. Keep the two in step;
  /// their tests share worked examples.
  ///
  /// It strips from the TAIL rather than splitting on the first comma, so a
  /// street like "100 Main St, Building A" keeps its second segment. With no
  /// locality fields to identify a tail (a legacy doc that predates them) it
  /// falls back to the first segment rather than guessing, and it never strips
  /// the last remaining one — a street that IS the city name must not reduce
  /// to nothing.
  ///
  /// **Idempotent**: an already-reduced street passes through untouched, which
  /// is what lets it run on a collection holding both shapes — the Wave import
  /// writes a street line, the app used to write the whole picked string.
  static String streetOnly(
    String stored, {
    String city = '',
    String province = '',
    String postalCode = '',
    String country = '',
  }) {
    final segments = stored
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.length <= 1) return segments.isEmpty ? '' : segments.first;

    final tails = <String>{};
    for (final part in [city, province, postalCode, country]) {
      final key = _localityKey(part);
      if (key.isNotEmpty) tails.add(key);
    }
    if (province.trim().isNotEmpty && postalCode.trim().isNotEmpty) {
      tails.add(_localityKey('$province $postalCode'));
    }
    if (tails.isEmpty) return segments.first;

    var end = segments.length;
    while (end > 1 && tails.contains(_localityKey(segments[end - 1]))) {
      end -= 1;
    }
    return segments.take(end).join(', ');
  }

  /// The whole address as one line, rebuilt from the street plus the structured
  /// fields — "1234 Rue Principale #4, Montréal, QC H2X 1Y4, Canada".
  ///
  /// Reducing through [streetOnly] FIRST is the load-bearing half: a legacy doc
  /// whose `address` still holds the locality would otherwise render its city
  /// twice. That makes this safe on both stored shapes and safe to re-apply to
  /// its own output.
  static String composeFull(
    String stored, {
    String city = '',
    String province = '',
    String postalCode = '',
    String country = '',
  }) {
    final street = canonicalToDisplay(
      streetOnly(
        stored,
        city: city,
        province: province,
        postalCode: postalCode,
        country: country,
      ),
    );
    // Province and postal code share a segment, the way an address is written.
    final region = [
      province.trim(),
      postalCode.trim(),
    ].where((part) => part.isNotEmpty).join(' ');
    return [
      street,
      city.trim(),
      region,
      country.trim(),
    ].where((part) => part.isNotEmpty).join(', ');
  }

  /// Collapses inner whitespace and case so two spellings of the same locality
  /// compare equal. Mirrors the JS `norm`.
  static String _localityKey(String value) =>
      value.replaceAll(_whitespaceRun, ' ').trim().toLowerCase();

  static String toCanonical(String text) {
    final trimmed = text.trim();
    final parts = splitApt(trimmed);
    if (parts == null) return trimmed;
    return combineAptAndStreet(parts.street, parts.apt);
  }

  static String _stripEmbeddedAptToken(String street) {
    return street.replaceAll(_embeddedAptToken, '').trim();
  }

  static ParsedAddressFields parse(String rawAddress) {
    final apt = splitApt(rawAddress);
    final value = (apt?.street ?? rawAddress).trim();
    if (value.isEmpty) {
      return ParsedAddressFields(apt: apt?.apt, street: apt?.street);
    }

    final parts = value
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    final postalMatch = _postalCode.firstMatch(value);
    final postalCode = postalMatch?.group(0)?.toUpperCase();

    String? country;
    if (parts.isNotEmpty) {
      final last = parts.last;
      if (postalCode != null &&
          last.toLowerCase().contains(postalCode.toLowerCase())) {
        country = 'Canada';
      } else if (last.length > 2) {
        country = last;
      }
    }

    String? province;
    for (final part in parts) {
      final m = _province.firstMatch(part);
      if (m != null) {
        province = m.group(0)!.toUpperCase();
        break;
      }
    }

    String? city;
    if (parts.length >= 3) {
      final candidate = parts[parts.length - 3];
      if (!_anyDigit.hasMatch(candidate)) city = candidate;
    } else if (parts.length >= 2) {
      final candidate = parts[parts.length - 2];
      if (!_anyDigit.hasMatch(candidate)) city = candidate;
    }

    return ParsedAddressFields(
      apt: apt?.apt,
      street: apt?.street,
      city: city,
      province: province,
      postalCode: postalCode,
      country: country,
    );
  }
}

class AptAddress {
  const AptAddress({required this.apt, required this.street});
  final String apt;
  final String street;
}

class ParsedAddressFields {
  const ParsedAddressFields({
    this.apt,
    this.street,
    this.city,
    this.province,
    this.country,
    this.postalCode,
  });

  final String? apt;
  final String? street;
  final String? city;
  final String? province;
  final String? country;
  final String? postalCode;
}
