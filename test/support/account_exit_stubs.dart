import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:scheduling/core/app/pending_photo_exit.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/images/appointment_image_loader.dart';
import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';

/// The dependency overrides every widget test reaching an account exit needs.
///
/// `deregisterThisDevice` forgets everything the session cached locally, and
/// each of the four fails a DIFFERENT way without an override. The image
/// loader resolves the platform cache directory through `path_provider`, and a
/// method channel never completes under `testWidgets`' fake clock — so the real
/// one makes the test HANG until its timeout rather than fail, with no error
/// naming the cause. The two repositories resolve `FirebaseFirestore.instance`
/// when their providers are READ (which `DeviceDeregistrationDeps.from` does),
/// so they throw `[core/no-app]` on construction before any teardown step runs.
///
/// `.claude/rules/testing.md` documented all three copies of this trio BY NAME
/// and stated that failure mode, which is the tell that it wanted one owner:
/// the rule had to list where each copy lived because there was nowhere to
/// point instead. Three files spelled it out — two of them byte-identical apart
/// from a class prefix, the third the recording variant — and the cost of a
/// fourth getting it subtly wrong is a hang with nothing in the output.
///
/// Pass [calls] to RECORD the teardown order (`'imageCache'`, `'clients'`,
/// `'appointments'`); leave it null for silent stubs. That is the only
/// difference between the two variants this replaces, so it is the only knob.
List<Override> accountExitStubOverrides({
  List<String>? calls,
  SessionFence? session,
  PendingPhotoExit? pendingPhotos,
}) => [
  sessionFenceProvider.overrideWithValue(
    session ?? SessionFence(readUid: () => 'test-uid'),
  ),
  appointmentImageLoaderProvider.overrideWithValue(_StubLoader(calls)),
  appointmentImageUploadProvider.overrideWithValue(
    _StubUploads(calls, pendingPhotos),
  ),
  clientsRepositoryProvider.overrideWithValue(_StubClients(calls)),
  appointmentsRepositoryProvider.overrideWithValue(_StubAppointments(calls)),
];

/// Subclassed rather than mocked: only `clear()` is under test, and the real
/// one would reach the file system.
class _StubLoader extends AppointmentImageLoader {
  _StubLoader(this.calls);

  final List<String>? calls;

  @override
  Future<void> clear() async => calls?.add('imageCache');
}

class _StubUploads extends AppointmentImageUploadService {
  _StubUploads(this.calls, this.pendingPhotos)
    : super(
        appointments: _StubAppointments(null),
        notifier: PhotoUploadNotifier(),
        storage: _StubImageStorage(),
        auth: _StubAuth(),
        employeeIdForUid: (_) async => null,
      );

  final List<String>? calls;
  final PendingPhotoExit? pendingPhotos;

  @override
  Future<PendingPhotoExit> prepareForExit() async =>
      pendingPhotos ?? const PendingPhotoExit(pendingCount: 0);

  @override
  Future<void> clearPending() async => calls?.add('imageUploads');
}

class _StubImageStorage implements ImageStorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubClients implements ClientsRepository {
  _StubClients(this.calls);

  final List<String>? calls;

  @override
  void clearCaches() => calls?.add('clients');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubAppointments implements AppointmentsRepository {
  _StubAppointments(this.calls);

  final List<String>? calls;

  @override
  void clearCaches() => calls?.add('appointments');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
