import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/images/images_providers.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/event_details_controller.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

class _ThrowingRepo implements AppointmentsRepository {
  @override
  Future<void> deleteAppointment(String id) async {
    throw Exception('boom');
  }

  @override
  Stream<void> get onLocalWrite => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _RecordingRepo implements AppointmentsRepository {
  _RecordingRepo({this.series = const []});

  final List<AppointmentRecord> series;
  final List<String> deletedIds = [];

  @override
  Future<void> deleteAppointment(String id) async {
    deletedIds.add(id);
  }

  @override
  Future<void> deleteAppointments(List<String> ids) async {
    deletedIds.addAll(ids);
  }

  @override
  Future<List<AppointmentRecord>> getSeries(String seriesId) async => series;

  @override
  Stream<void> get onLocalWrite => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _RecordingStorage implements ImageStorageService {
  final List<AppointmentImage> deleted = [];

  @override
  Future<void> deleteImages(List<AppointmentImage> images) async {
    deleted.addAll(images);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  test(
    'deleteAppointment returns the error when the repository throws',
    () async {
      final container = ProviderContainer(
        overrides: [
          isOfflineProvider.overrideWithValue(false),
          appointmentsRepositoryProvider.overrideWithValue(_ThrowingRepo()),
        ],
      );
      addTearDown(container.dispose);

      final appointment = AppointmentRecord(
        id: 'a1',
        startTime: DateTime(2026, 6, 6, 9),
        endTime: DateTime(2026, 6, 6, 10),
      );
      final provider = eventDetailsControllerProvider(
        EventDetailsKey(appointment),
      );
      // Keep the autoDispose family's state alive across reads (see testing.md).
      final sub = container.listen(provider, (_, _) {});
      addTearDown(sub.close);

      final outcome = await container
          .read(provider.notifier)
          .deleteAppointment(appointment);

      expect(outcome, isA<EventDetailsActionFailed>());
      expect(
        (outcome as EventDetailsActionFailed).error.toString(),
        contains('boom'),
      );
    },
  );

  // Photo cleanup on delete moved to `cascadeDeleteAppointmentImages` at the
  // CONTRACT step, and these two pin the client half of that handover.
  //
  // It was not a tidy-up. The client used to enumerate `appointment.pictures`
  // to know which Storage objects to remove, and that array is gone — a client
  // that no longer reads the photos cannot list what to delete. Reaching for
  // Storage here now would delete nothing (there is nothing to enumerate) while
  // looking like cleanup, which is exactly how bytes orphan invisibly.
  test('deleting an appointment leaves its photos to the server', () async {
    final repo = _RecordingRepo();
    final storage = _RecordingStorage();
    final container = ProviderContainer(
      overrides: [
        isOfflineProvider.overrideWithValue(false),
        appointmentsRepositoryProvider.overrideWithValue(repo),
        imageStorageProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(container.dispose);

    final appointment = AppointmentRecord(
      id: 'a1',
      startTime: DateTime(2026, 6, 6, 9),
      endTime: DateTime(2026, 6, 6, 10),
      pictureCount: 2,
    );
    final provider = eventDetailsControllerProvider(
      EventDetailsKey(appointment),
    );
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);

    final outcome = await container
        .read(provider.notifier)
        .deleteAppointment(appointment);

    expect(outcome, isA<EventDetailsActionOk>());
    expect(repo.deletedIds, ['a1']);
    expect(storage.deleted, isEmpty);
  });

  test('a series delete deletes the documents and nothing else', () async {
    // Each deleted document fires its own cascade, so the server covers the
    // future visits too — and the preserved ones keep their photos precisely
    // because their documents survive.
    final base = DateTime(2026, 6, 6, 9);
    final deleted = AppointmentRecord(
      id: 's1',
      seriesId: 's1',
      startTime: base,
      endTime: base.add(const Duration(hours: 1)),
      pictureCount: 1,
    );
    final futureVisit = AppointmentRecord(
      id: 's2',
      seriesId: 's1',
      startTime: base.add(const Duration(days: 120)),
      endTime: base.add(const Duration(days: 120, hours: 1)),
      pictureCount: 1,
    );
    // A completed future visit is preserved as a record — and so are its bytes.
    final doneVisit = AppointmentRecord(
      id: 's3',
      seriesId: 's1',
      startTime: base.add(const Duration(days: 240)),
      endTime: base.add(const Duration(days: 240, hours: 1)),
      status: 'done',
      pictureCount: 1,
    );

    final repo = _RecordingRepo(series: [deleted, futureVisit, doneVisit]);
    final storage = _RecordingStorage();
    final container = ProviderContainer(
      overrides: [
        isOfflineProvider.overrideWithValue(false),
        appointmentsRepositoryProvider.overrideWithValue(repo),
        imageStorageProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(container.dispose);

    final provider = eventDetailsControllerProvider(EventDetailsKey(deleted));
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);

    final outcome = await container
        .read(provider.notifier)
        .deleteAppointment(deleted, includeFuture: true);

    expect(outcome, isA<EventDetailsActionOk>());
    expect(repo.deletedIds, ['s1', 's2']);
    expect(storage.deleted, isEmpty);
  });
}
