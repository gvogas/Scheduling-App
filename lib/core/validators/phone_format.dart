import 'package:flutter/services.dart';

final RegExp _nonDigit = RegExp(r'\D');
final RegExp _allowedPhoneChars = RegExp(r'^[0-9()+.\-\s#]+$');

/// A trailing extension, in either language: `ext 12`, `x5`, `poste 2`, `p. 7`.
///
/// It is matched rather than tolerated because the two things that used to
/// happen to it were both wrong: `[…extEXT]` in the character class accepted
/// any arrangement of those letters (`text` passed) while rejecting `poste` on
/// a bilingual product, and `bareNumber` folded the extension's digits onto the
/// number itself, so `514-555-1234 poste 2` was STORED as `51455512342` — a
/// number nobody can dial, written silently on an ordinary save.
final RegExp _extensionSuffix = RegExp(
  r'(?:ext|poste|post|x|p)\.?\s*\d+\s*$',
  caseSensitive: false,
);

/// Digits of [value], with every separator dropped.
String phoneDigits(String value) => value.replaceAll(_nonDigit, '');

/// [phone] reduced to a bare number — `(514) 555-1234` becomes `5145551234` —
/// keeping a leading `+` so an international number stays dialable.
///
/// Falls back to the trimmed input when there is nothing to strip: an
/// extension-only or alphabetic entry is still better handed on than blanked.
///
/// The single owner of that rule. It backs both `dialableUri` (some dialers
/// reject the percent-encoded brackets) and `ClientNamePolicy.composeStored`
/// (a person's stored `name` IS the Wave customer name, and Wave shows it
/// bare).
String bareNumber(String phone) {
  final trimmed = phone.trim();
  final digits = phoneDigits(trimmed);
  if (digits.isEmpty) return trimmed;
  return trimmed.startsWith('+') ? '+$digits' : digits;
}

/// Canonical value for persisted phone fields.
///
/// UI fields may keep a friendly mask while the user types, but Firestore keeps
/// the searchable/dialable core so edits do not preserve arbitrary punctuation.
/// An extension survives as its own trailing token — see [_extensionSuffix].
String normalizePhoneForStorage(String phone) {
  final trimmed = phone.trim();
  final match = _extensionSuffix.firstMatch(trimmed);
  if (match == null) return bareNumber(trimmed);
  final core = bareNumber(trimmed.substring(0, match.start).trim());
  final extension = trimmed.substring(match.start).trim();
  return core.isEmpty ? extension : '$core $extension';
}

/// Flexible validity check for typed phone fields.
///
/// Allows common punctuation and extension markers while requiring enough
/// digits to be dialable.
bool isUsablePhoneNumber(String phone) {
  final trimmed = phone.trim();
  if (trimmed.isEmpty) return true;
  final core = trimmed.replaceFirst(_extensionSuffix, '').trim();
  return _allowedPhoneChars.hasMatch(core) && phoneDigits(core).length >= 7;
}

/// Renders a North-American number as `(514) 555-1234`, formatting
/// progressively so a half-typed number reads sensibly (`(514) 55`).
///
/// Two deliberate pass-throughs, because this app stores whatever the admin
/// typed and a formatter that "corrects" a number it doesn't understand loses
/// data that can no longer be dialled:
///
/// * anything containing `+` is returned untouched — an international number
///   has no fixed 10-digit shape, and bracketing its first three digits as an
///   area code would be wrong.
/// * digits past the tenth are appended verbatim (` 5678`), so an extension or
///   a longer foreign number survives rather than being silently truncated.
String formatPhoneNumber(String value) {
  if (value.contains('+')) return value;

  final digits = phoneDigits(value);
  if (digits.isEmpty) return '';

  final buffer = StringBuffer('(')
    ..write(digits.substring(0, digits.length.clamp(0, 3)));
  if (digits.length < 4) return buffer.toString();

  buffer
    ..write(') ')
    ..write(digits.substring(3, digits.length.clamp(0, 6)));
  if (digits.length < 7) return buffer.toString();

  buffer
    ..write('-')
    ..write(digits.substring(6, digits.length.clamp(0, 10)));
  if (digits.length > 10) buffer.write(' ${digits.substring(10)}');
  return buffer.toString();
}

/// Applies [formatPhoneNumber] as the user types, carrying the caret through
/// the mask: it lands after the same count of digits it followed before, so a
/// mid-number correction keeps its place instead of jumping to the end.
class PhoneInputFormatter extends TextInputFormatter {
  const PhoneInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final formatted = formatPhoneNumber(newValue.text);
    if (formatted == newValue.text) return newValue;
    final caret = newValue.selection.extentOffset;
    final digitsBefore = caret < 0
        ? phoneDigits(newValue.text).length
        : phoneDigits(newValue.text.substring(0, caret)).length;
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(
        offset: _offsetAfterDigits(formatted, digitsBefore),
      ),
    );
  }

  /// Index just past the [count]-th digit of [text]; 0 for none, the end when
  /// [text] has fewer digits.
  static int _offsetAfterDigits(String text, int count) {
    if (count == 0) return 0;
    var seen = 0;
    for (var i = 0; i < text.length; i++) {
      if (!_nonDigit.hasMatch(text[i]) && ++seen == count) return i + 1;
    }
    return text.length;
  }
}
