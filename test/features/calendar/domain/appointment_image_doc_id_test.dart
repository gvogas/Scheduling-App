import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/policies/appointment_image_doc_id.dart';

import '../../../fixtures/shared/shared_fixture.dart';

// Exact-id examples are shared with jest: test/fixtures/shared/image_ids.json.
void main() {
  final cap =
      loadSharedFixture('constants.json')['appointmentImageIdMaxLength'] as int;

  group('shared examples', () {
    for (final c in sharedCases(loadSharedFixture('image_ids.json'), 'cases')) {
      test(c['name'] as String, () {
        expect(
          appointmentImageDocIdFor(
            storagePath: c['storagePath'] as String,
            url: c['url'] as String,
          ),
          c['expect'],
        );
      });
    }
  });

  test('fields other than storagePath and url do not change the id', () {
    const path =
        'appointments/aBc123XyZ/images/1754835600000_image_picker_A1.jpg';
    expect(
      appointmentImageDocId(const AppointmentImage(storagePath: path)),
      appointmentImageDocId(
        const AppointmentImage(
          storagePath: path,
          fileName: 'something_else.jpg',
        ),
      ),
    );
    expect(appointmentImageDocId(const AppointmentImage()), '');
  });

  test('caps length while keeping the unique tail', () {
    final long = 'appointments/${'x' * 500}/images/UNIQUE_TAIL.jpg';
    final id = appointmentImageDocIdFor(storagePath: long, url: '');
    expect(id.length, 'img_'.length + cap);
    expect(id, endsWith('UNIQUE_TAIL.jpg'));
  });

  test('two long paths differing only in their tail do not collide', () {
    final a = 'appointments/${'x' * 500}/images/TAIL_A.jpg';
    final b = 'appointments/${'x' * 500}/images/TAIL_B.jpg';
    expect(
      appointmentImageDocIdFor(storagePath: a, url: ''),
      isNot(appointmentImageDocIdFor(storagePath: b, url: '')),
    );
  });
}
