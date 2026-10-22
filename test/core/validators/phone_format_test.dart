import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/validators/phone_format.dart';

TextEditingValue _type(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  group('formatPhoneNumber', () {
    test('formats a full North-American number', () {
      expect(formatPhoneNumber('5145551234'), '(514) 555-1234');
    });

    test('formats progressively while typing', () {
      expect(formatPhoneNumber('5'), '(5');
      expect(formatPhoneNumber('514'), '(514');
      expect(formatPhoneNumber('5145'), '(514) 5');
      expect(formatPhoneNumber('514555'), '(514) 555');
      expect(formatPhoneNumber('5145551'), '(514) 555-1');
    });

    test('is idempotent on already-formatted input', () {
      expect(formatPhoneNumber('(514) 555-1234'), '(514) 555-1234');
    });

    test('reformats a number typed with other separators', () {
      expect(formatPhoneNumber('514-555-1234'), '(514) 555-1234');
      expect(formatPhoneNumber('514.555.1234'), '(514) 555-1234');
    });

    test('empty stays empty', () {
      expect(formatPhoneNumber(''), '');
      expect(formatPhoneNumber('   '), '');
    });

    test('passes an international number through untouched', () {
      expect(formatPhoneNumber('+33 6 12 34 56 78'), '+33 6 12 34 56 78');
      expect(formatPhoneNumber('+15145551234'), '+15145551234');
    });

    test('keeps digits past the tenth instead of truncating', () {
      expect(formatPhoneNumber('5145551234567'), '(514) 555-1234 567');
    });
  });

  group('phoneDigits', () {
    test('strips every separator', () {
      expect(phoneDigits('(514) 555-1234'), '5145551234');
      expect(phoneDigits('+1 514 555 1234'), '15145551234');
    });
  });

  group('PhoneInputFormatter', () {
    const formatter = PhoneInputFormatter();

    test('formats as the user types and parks the caret at the end', () {
      final result = formatter.formatEditUpdate(_type('514'), _type('5145'));
      expect(result.text, '(514) 5');
      expect(result.selection.baseOffset, '(514) 5'.length);
    });

    test('leaves an unchanged value alone, caret included', () {
      // A no-op edit must not move the caret, or deleting mid-number would
      // yank the cursor to the end on every keystroke.
      const mid = TextEditingValue(
        text: '+33 6 12 34 56 78',
        selection: TextSelection.collapsed(offset: 4),
      );
      final result = formatter.formatEditUpdate(mid, mid);
      expect(result.selection.baseOffset, 4);
    });

    test('deleting a digit reformats down', () {
      final result = formatter.formatEditUpdate(
        _type('(514) 555-1234'),
        _type('(514) 555-123'),
      );
      expect(result.text, '(514) 555-123');
    });

    test('deleting a mid-number digit keeps the caret where it was', () {
      // "(514) 5|55-1234" → backspace → the raw edit is "(514) |55-1234" with
      // the caret at 6, three digits in; the reformatted text puts it right
      // after the third digit ("(514|) 551-234") — never at the end, and
      // before the mask characters so the next backspace still takes a digit.
      final result = formatter.formatEditUpdate(
        const TextEditingValue(
          text: '(514) 555-1234',
          selection: TextSelection.collapsed(offset: 7),
        ),
        const TextEditingValue(
          text: '(514) 55-1234',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      expect(result.text, '(514) 551-234');
      expect(result.selection.baseOffset, 4);
    });

    test('inserting a mid-number digit lands the caret after it', () {
      // "(514) 55|1-234" → type 5 → "(514) 555|1-234" (caret 9) → formatted
      // "(514) 555-1234" with the caret after the sixth digit, before the dash.
      final result = formatter.formatEditUpdate(
        const TextEditingValue(
          text: '(514) 551-234',
          selection: TextSelection.collapsed(offset: 8),
        ),
        const TextEditingValue(
          text: '(514) 5551-234',
          selection: TextSelection.collapsed(offset: 9),
        ),
      );
      expect(result.text, '(514) 555-1234');
      expect(result.selection.baseOffset, 9);
    });

    test('a caret before every digit stays at the start', () {
      final result = formatter.formatEditUpdate(
        _type('514'),
        const TextEditingValue(
          text: '5514',
          selection: TextSelection.collapsed(offset: 0),
        ),
      );
      expect(result.text, '(551) 4');
      expect(result.selection.baseOffset, 0);
    });
  });

  group('bareNumber', () {
    test('takes the punctuation off a stored number', () {
      // `clients/{id}.name` is the Wave customer name, and the invoicing
      // workflow there wants the number unpunctuated.
      expect(bareNumber('(514) 555-1234'), '5145551234');
      expect(bareNumber('514-555-1234'), '5145551234');
    });

    test('keeps a leading + so an international number stays dialable', () {
      expect(bareNumber('+33 1 42 68 53 00'), '+33142685300');
    });

    test('keeps a leading country-code 1', () {
      // Unlike the comparison-only digit normalizer inside ClientNamePolicy,
      // this produces a value that gets STORED — dropping a digit the admin
      // typed would change the number.
      expect(bareNumber('1-514-555-1234'), '15145551234');
    });

    test('hands back anything it cannot reduce', () {
      expect(bareNumber('  ext. only  '), 'ext. only');
      expect(bareNumber(''), '');
    });
  });

  group('extensions survive storage and validation', () {
    test(
      'an extension is kept as its own token, not folded into the number',
      () {
        // `bareNumber` alone produced 51455512342 — a number nobody can dial,
        // written silently on an ordinary save.
        expect(
          normalizePhoneForStorage('514-555-1234 poste 2'),
          '5145551234 poste 2',
        );
        expect(
          normalizePhoneForStorage('(514) 555-1234 ext 12'),
          '5145551234 ext 12',
        );
        expect(normalizePhoneForStorage('(514) 555-1234'), '5145551234');
      },
    );

    test('both languages validate, and a word is still not a number', () {
      expect(isUsablePhoneNumber('514-555-1234 poste 2'), isTrue);
      expect(isUsablePhoneNumber('5145551234 x5'), isTrue);
      expect(isUsablePhoneNumber('text'), isFalse);
      expect(isUsablePhoneNumber('12345'), isFalse);
      expect(isUsablePhoneNumber(''), isTrue);
    });
  });
}
