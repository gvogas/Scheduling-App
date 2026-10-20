import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/policies/phone_query_policy.dart';

void main() {
  group('isPhoneQuery', () {
    test('digits and separators only', () {
      expect(PhoneQueryPolicy.isPhoneQuery('(514) 562-8332'), isTrue);
      expect(PhoneQueryPolicy.isPhoneQuery('5145628332'), isTrue);
      expect(PhoneQueryPolicy.isPhoneQuery('514'), isTrue);
    });

    test('anything with a letter is a text query', () {
      expect(PhoneQueryPolicy.isPhoneQuery('tremblay'), isFalse);
      expect(PhoneQueryPolicy.isPhoneQuery('4820 Wellington'), isFalse);
      expect(PhoneQueryPolicy.isPhoneQuery('H4G 1X2'), isFalse);
    });

    test('empty or punctuation-only is neither', () {
      expect(PhoneQueryPolicy.isPhoneQuery(''), isFalse);
      expect(PhoneQueryPolicy.isPhoneQuery('()-'), isFalse);
    });
  });

  group('canonicalDigits', () {
    test('strips separators', () {
      expect(PhoneQueryPolicy.canonicalDigits('(514) 562-8332'), '5145628332');
    });

    // A leading 1 is a habit, not a digit of the number. Stored numbers are
    // exactly ten digits (normalizePhoneForStorage -> bareNumber), so an
    // 11-digit token is a substring of nothing.
    test('drops a leading 1 when that leaves ten digits', () {
      expect(PhoneQueryPolicy.canonicalDigits('15145628332'), '5145628332');
      expect(PhoneQueryPolicy.canonicalDigits('1 514 562 8332'), '5145628332');
    });

    test('leaves an 11-digit string that does not start with 1 alone', () {
      expect(PhoneQueryPolicy.canonicalDigits('51456283322'), '51456283322');
    });

    test('leaves short input alone', () {
      expect(PhoneQueryPolicy.canonicalDigits('1514'), '1514');
    });
  });

  group('ladder', () {
    test('below the minimum it sends nothing', () {
      expect(PhoneQueryPolicy.ladder('514'), isEmpty);
      expect(PhoneQueryPolicy.ladder('514562'), isEmpty);
    });

    test('at seven digits it sends exactly one rung', () {
      final rungs = PhoneQueryPolicy.ladder('5145628');
      expect(rungs, hasLength(1));
      expect(rungs.single.rung, PhoneRung.canonical);
      expect(rungs.single.digits, '5145628');
    });

    test('a partial eight or nine digits still sends only the canonical', () {
      expect(PhoneQueryPolicy.ladder('51456283'), hasLength(1));
      expect(PhoneQueryPolicy.ladder('514562833'), hasLength(1));
    });

    test(
      'a full ten digits sends canonical, then first seven, then last seven',
      () {
        final rungs = PhoneQueryPolicy.ladder('5145628332');
        expect(rungs.map((r) => r.rung).toList(), [
          PhoneRung.canonical,
          PhoneRung.firstSeven,
          PhoneRung.lastSeven,
        ]);
        expect(rungs[0].digits, '5145628332');
        expect(rungs[1].digits, '5145628');
        expect(rungs[2].digits, '5628332');
      },
    );

    test('a leading 1 is absorbed before the ladder is built', () {
      final rungs = PhoneQueryPolicy.ladder('1 (514) 562-8332');
      expect(rungs[0].digits, '5145628332');
      expect(rungs[1].digits, '5145628');
    });

    // F1: this is the case the design doc's last-7/last-4 ladder missed.
    test('the first-seven rung rescues a transposition in the tail', () {
      const stored = '5145628332';
      final rungs = PhoneQueryPolicy.ladder('5145628233');
      expect(
        stored.contains(rungs[0].digits),
        isFalse,
        reason: 'canonical misses',
      );
      expect(
        stored.contains(rungs[1].digits),
        isTrue,
        reason: 'first seven hits',
      );
    });

    // The other direction: a wrong area code with a correct local number.
    test('the last-seven rung rescues a wrong area code', () {
      const stored = '5145628332';
      final rungs = PhoneQueryPolicy.ladder('4385628332');
      expect(stored.contains(rungs[0].digits), isFalse);
      expect(stored.contains(rungs[1].digits), isFalse);
      expect(stored.contains(rungs[2].digits), isTrue);
    });

    test('an over-long typo keeps a usable head rung', () {
      const stored = '5145628332';
      final rungs = PhoneQueryPolicy.ladder('51456283322');
      expect(rungs[1].digits, '5145628');
      expect(stored.contains(rungs[1].digits), isTrue);
    });

    test('rungs are de-duplicated when the number is exactly seven digits', () {
      final rungs = PhoneQueryPolicy.ladder('5628332');
      expect(rungs.map((r) => r.digits).toSet(), hasLength(1));
    });
  });

  group('fallbacksAllowed', () {
    // Fallbacks must not fire while he is still typing; only once the number
    // looks finished. Otherwise every partial spends three round trips.
    test('only at ten digits or more', () {
      expect(PhoneQueryPolicy.fallbacksAllowed('5145628'), isFalse);
      expect(PhoneQueryPolicy.fallbacksAllowed('514562833'), isFalse);
      expect(PhoneQueryPolicy.fallbacksAllowed('5145628332'), isTrue);
      expect(PhoneQueryPolicy.fallbacksAllowed('51456283322'), isTrue);
    });
  });
}
