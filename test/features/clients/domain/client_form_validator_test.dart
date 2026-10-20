import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_form_validator.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Map<String, String?> validate({
    String name = '',
    String firstName = '',
    String lastName = '',
    String phone = '',
    String mobile = '',
    String email = '',
    String address = '',
    List<ClientContact> additionalContacts = const [],
    bool noFixedAddress = false,
  }) {
    return ClientFormValidator.validate(
      l10n: l10n,
      name: name,
      firstName: firstName,
      lastName: lastName,
      phone: phone,
      mobile: mobile,
      email: email,
      address: address,
      additionalContacts: additionalContacts,
      noFixedAddress: noFixedAddress,
    );
  }

  group('ClientFormValidator', () {
    test('a name, phone, and address produce no errors', () {
      final errors = validate(
        name: 'Jane',
        phone: '555-1234',
        address: '1 Main St',
      );
      expect(errors.values.where((e) => e != null), isEmpty);
    });

    test('a missing customer name flags the name field', () {
      final errors = validate(phone: '555-1234', address: '1 Main St');
      expect(errors['name'], isNotNull);
    });

    test('first/last name and mobile are optional', () {
      final errors = validate(name: 'Jane', address: '1 Main St');
      expect(errors.values.where((e) => e != null), isEmpty);
    });

    test('phone and email are optional — a name and address are enough', () {
      final errors = validate(name: 'Jane', address: '1 Main St');
      expect(errors.values.where((e) => e != null), isEmpty);
    });

    test('a malformed email is rejected', () {
      final errors = validate(
        name: 'Jane',
        phone: '555-1234',
        email: 'not-an-email',
        address: '1 Main St',
      );
      expect(errors['email'], isNotNull);
    });

    test('malformed phone values are rejected without requiring phone', () {
      expect(
        validate(name: 'Jane', phone: 'abc', address: '1 Main St')['phone'],
        isNotNull,
      );
      expect(
        validate(
          name: 'Jane',
          phone: '(514) 555-1234 ext 9',
          address: '1 Main St',
        )['phone'],
        isNull,
      );
      expect(validate(name: 'Jane', address: '1 Main St')['phone'], isNull);
    });

    test('additional-contact phone values are format-checked', () {
      final errors = validate(
        name: 'Acme',
        address: '1 Main St',
        additionalContacts: const [ClientContact(name: 'Bob', phone: 'abc')],
      );

      expect(errors['contact_0_phone'], isNotNull);
    });

    test('address is required whenever not marked no-fixed-address', () {
      expect(validate(name: 'Jane', phone: '555-1234')['address'], isNotNull);
      expect(
        validate(
          name: 'Jane',
          phone: '555-1234',
          address: '1 Main St',
        )['address'],
        isNull,
      );
    });

    test('an all-empty contact card is skipped but keeps its index', () {
      final errors = validate(
        name: 'Acme',
        phone: '555-1234',
        additionalContacts: const [
          ClientContact(),
          ClientContact(phone: '555-9876'),
        ],
      );
      expect(errors.containsKey('contact_0_name'), isFalse);
      expect(errors['contact_1_name'], isNotNull);
    });

    test('a contact needs a phone or email', () {
      final errors = validate(
        name: 'Acme',
        phone: '555-1234',
        additionalContacts: const [ClientContact(name: 'Bob')],
      );
      expect(errors['contact_0_phone'], isNotNull);
    });

    test('noFixedAddress skips the address requirement', () {
      final errors = validate(
        name: 'City Hall',
        phone: '555-1234',
        noFixedAddress: true,
      );
      expect(errors['address'], isNull);
    });

    test('noFixedAddress still validates a typed email', () {
      final errors = validate(
        name: 'City Hall',
        phone: '555-1234',
        email: 'not-an-email',
        noFixedAddress: true,
      );
      expect(errors['email'], isNotNull);
    });
  });
}
