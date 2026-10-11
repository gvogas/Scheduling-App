import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/domain/models/appointment_prefill.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/maps/domain/address_parser.dart';

const _client = ClientRecord(
  id: 'c1',
  name: 'Acme Plumbing',
  phone: '5145550000',
  address: '12 Main St',
  city: 'Montréal',
);

/// The stored spelling of the client's own address, as a save writes it.
final _clientAddress = AddressParser.toCanonical(_client.fullAddress);

/// Only what a repeat booking should carry.
final _bare = AppointmentRecord(
  startTime: DateTime(2026, 5, 10, 9),
  endTime: DateTime(2026, 5, 10, 10, 30),
  title: 'Water heater',
  clientId: 'c1',
  clientName: 'Acme Plumbing',
  clientPhone: '5145550000',
  employeeIds: const ['e1', 'e2'],
  employeeNames: const ['Alex', 'Bea'],
  address: _clientAddress,
  notes: 'Gate code 4821',
  materialsNeeded: 'anode rod',
);

/// The same job with EVERY field that belongs to the visit itself set to a
/// non-default value.
final _finished = _bare.copyWith(
  id: 'appt-old',
  fieldNotes: 'Replaced the anode rod',
  status: 'done',
  repeat: RepeatInterval.sixMonths,
  seriesId: 'appt-old',
  dayIndex: 2,
  dayCount: 3,
  createdAt: DateTime(2026, 5),
  updatedAt: DateTime(2026, 5, 10, 12),
  pictureCount: 3,
  startedAt: DateTime(2026, 5, 10, 9, 5),
  completedAt: DateTime(2026, 5, 10, 10, 40),
);

void main() {
  group('AppointmentPrefill.bookAgain', () {
    test('carries the who and the what of the job, and its length', () {
      expect(
        AppointmentPrefill.bookAgain(_finished, client: _client),
        // At the client's own address, so the pill mode and no custom text.
        const AppointmentPrefill(
          client: _client,
          title: 'Water heater',
          notes: 'Gate code 4821',
          materialsNeeded: 'anode rod',
          employeeIds: ['e1', 'e2'],
          durationMinutes: 90,
        ).copyWith(address: _clientAddress),
      );
    });

    test('carries nothing of the visit itself', () {
      // Status, photos, field notes, the time record, the series and run
      // fields, ids and timestamps: a source with all of them set yields the
      // same draft as one with none.
      expect(
        AppointmentPrefill.bookAgain(_finished, client: _client),
        AppointmentPrefill.bookAgain(_bare, client: _client),
      );
    });

    test('uses a custom address when the job was not at the client', () {
      final elsewhere = _bare.copyWith(address: '99 Other Rd');
      final prefill = AppointmentPrefill.bookAgain(elsewhere, client: _client);
      expect(prefill.useCustomAddress, isTrue);
      expect(prefill.address, '99 Other Rd');
    });

    test('a no-fixed-address client is always custom', () {
      final prefill = AppointmentPrefill.bookAgain(
        _bare,
        client: _client.copyWith(noFixedAddress: true),
      );
      expect(prefill.useCustomAddress, isTrue);
    });

    test('an all-day block carries no length', () {
      final allDay = _bare.copyWith(
        isAllDay: true,
        startTime: DateTime(2026, 5, 10),
        endTime: DateTime(2026, 5, 10, 23, 59),
      );
      expect(
        AppointmentPrefill.bookAgain(allDay, client: _client).durationMinutes,
        isNull,
      );
    });

    test('a span wider than a day carries no length', () {
      final wide = _bare.copyWith(
        startTime: DateTime(2026, 5, 10, 9),
        endTime: DateTime(2026, 5, 12, 17),
      );
      expect(
        AppointmentPrefill.bookAgain(wide, client: _client).durationMinutes,
        isNull,
      );
    });

    test('an empty window carries no length', () {
      final empty = _bare.copyWith(endTime: _bare.startTime);
      expect(
        AppointmentPrefill.bookAgain(empty, client: _client).durationMinutes,
        isNull,
      );
    });
  });
}
