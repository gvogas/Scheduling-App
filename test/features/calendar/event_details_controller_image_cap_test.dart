import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/images/images_providers.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/event_details_controller.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';

/// L3: `EventDetailsController.addImages` caps `existingImages + newImages` at
/// `maxImagesPerAppointment` (10), counting existing images since they'll
/// still be on the appointment after save.
///
/// Since the CONTRACT step the existing photos arrive from the `images`
/// subcollection rather than off the appointment document, so each case has to
/// let that read settle before it counts as "existing" — which is also the
/// point: a cap computed before the read lands would let a full job take ten
/// more.

class _MockAppointmentsRepo extends Mock implements AppointmentsRepository {}

class _MockClientsRepo extends Mock implements ClientsRepository {}

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockUploader extends Mock implements AppointmentImageUploadService {}

class _MockStorage extends Mock implements ImageStorageService {}

AppointmentImage _image(int i) => AppointmentImage(
  storagePath: 'appointments/appt-1/images/img$i.jpg',
  fileName: 'img$i.jpg',
);

AppointmentRecord _appointmentWith(int existingCount) => AppointmentRecord(
  id: 'appt-1',
  title: 'Leak fix',
  startTime: DateTime(2026, 5, 10, 9),
  endTime: DateTime(2026, 5, 10, 10),
  pictureCount: existingCount,
  status: 'booked',
);

void main() {
  setUpAll(() {
    registerFallbackValue(<AppointmentImage>[]);
  });

  late _MockAppointmentsRepo appointments;
  late _MockClientsRepo clients;
  late _MockEmployeesRepo employees;
  late _MockUploader uploader;
  late _MockStorage storage;

  setUp(() {
    appointments = _MockAppointmentsRepo();
    clients = _MockClientsRepo();
    employees = _MockEmployeesRepo();
    uploader = _MockUploader();
    when(
      () => uploader.enqueuePhotos(
        appointmentId: any(named: 'appointmentId'),
        newImages: any(named: 'newImages'),
      ),
    ).thenAnswer((_) async {});
    storage = _MockStorage();
    // Empty client id short-circuits the seed lookup; empty employee stream
    // keeps build()'s microtasks from blocking.
    when(employees.watchEmployees).thenAnswer((_) => Stream.value(const []));
    when(
      () => appointments.onLocalWrite,
    ).thenAnswer((_) => const Stream.empty());
  });

  ProviderContainer makeContainer(AppointmentRecord appointment) {
    when(
      () => appointments.fetchAppointmentPictures('appt-1'),
    ).thenAnswer((_) async => List.generate(appointment.pictureCount, _image));
    final c =
        ProviderContainer(
            overrides: [
              appointmentsRepositoryProvider.overrideWithValue(appointments),
              clientsRepositoryProvider.overrideWithValue(clients),
              employeesRepositoryProvider.overrideWithValue(employees),
              appointmentImageUploadProvider.overrideWithValue(uploader),
              imageStorageProvider.overrideWithValue(storage),
            ],
          )
          // Keep the AutoDispose family-keyed provider alive across reads.
          ..listen(
            eventDetailsControllerProvider(EventDetailsKey(appointment)),
            (_, _) {},
          );
    addTearDown(c.dispose);
    return c;
  }

  /// Lets `build()`'s microtask and the awaited subcollection read settle.
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  List<File> stubFiles(int count) =>
      List.generate(count, (i) => File('/tmp/stub_$i.jpg'));

  test('3 existing + addImages([5]) keeps all 5 new (8 total)', () async {
    final appt = _appointmentWith(3);
    final c = makeContainer(appt);
    await settle();
    c
        .read(eventDetailsControllerProvider(EventDetailsKey(appt)).notifier)
        .addImages(stubFiles(5));

    final state = c.read(eventDetailsControllerProvider(EventDetailsKey(appt)));
    expect(state.existingImages.length, 3);
    expect(state.newImages.length, 5);
  });

  test('3 existing + addImages([10]) truncates new to 7 (10 total)', () async {
    final appt = _appointmentWith(3);
    final c = makeContainer(appt);
    await settle();
    c
        .read(eventDetailsControllerProvider(EventDetailsKey(appt)).notifier)
        .addImages(stubFiles(10));

    final state = c.read(eventDetailsControllerProvider(EventDetailsKey(appt)));
    expect(state.existingImages.length, 3);
    expect(state.newImages.length, 7);
  });

  test(
    '10 existing + addImages([2]) keeps newImages empty (already capped)',
    () async {
      final appt = _appointmentWith(10);
      final c = makeContainer(appt);
      await settle();
      c
          .read(eventDetailsControllerProvider(EventDetailsKey(appt)).notifier)
          .addImages(stubFiles(2));

      final state = c.read(
        eventDetailsControllerProvider(EventDetailsKey(appt)),
      );
      expect(state.existingImages.length, 10);
      expect(state.newImages.length, 0);
    },
  );
}
