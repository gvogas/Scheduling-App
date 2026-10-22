import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/analytics/analytics_service.dart';
import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/app/pending_photo_exit.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/images/appointment_image_loader.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/live_activity/application/live_activity_registration_controller.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/l10n/l10n.dart';

class _Uploads extends Mock implements AppointmentImageUploadService {}

class _Auth extends Mock implements AuthService {}

class _Analytics extends Mock implements AnalyticsService {}

class _Push extends Mock implements PushRegistrationController {}

class _Presence extends Mock implements PresenceSyncController {}

class _LiveActivity extends Mock
    implements LiveActivityRegistrationController {}

class _ImageLoader extends Mock implements AppointmentImageLoader {}

class _Clients extends Mock implements ClientsRepository {}

class _Appointments extends Mock implements AppointmentsRepository {}

void main() {
  late _Uploads uploads;
  late SessionFence session;
  String? uid;
  PendingPhotoExit? result;
  var resumes = 0;

  setUp(() {
    uploads = _Uploads();
    uid = 'uid-1';
    session = SessionFence(readUid: () => uid);
    result = null;
    resumes = 0;
  });

  Future<void> start(WidgetTester tester, {String language = 'en'}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: lightTheme(),
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await confirmPendingPhotoExit(
                  context,
                  uploads,
                  session,
                );
              },
              child: const Text('start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
  }

  testWidgets('empty queues continue without a discard prompt', (tester) async {
    when(
      uploads.prepareForExit,
    ).thenAnswer((_) async => const PendingPhotoExit(pendingCount: 0));

    await start(tester);

    expect(result?.pendingCount, 0);
    expect(find.text('Photos waiting to save'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a superseded queue inspection cannot authorize even an empty exit',
    (tester) async {
      when(uploads.prepareForExit).thenAnswer(
        (_) async => PendingPhotoExit(
          pendingCount: 0,
          readCurrent: () => false,
          onResume: () => resumes++,
        ),
      );

      await start(tester);

      expect(result, isNull);
      expect(resumes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a session change during queue inspection is a quiet no-op', (
    tester,
  ) async {
    when(uploads.prepareForExit).thenAnswer((_) async => null);

    await start(tester);

    expect(result, isNull);
    expect(find.text('Photos waiting to save'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'fr']) {
    testWidgets(
      'stay retries without authorizing exit in $language at 2x text',
      (tester) async {
        when(uploads.prepareForExit).thenAnswer(
          (_) async =>
              PendingPhotoExit(pendingCount: 2, onResume: () => resumes++),
        );

        await start(tester, language: language);
        await tester.tap(
          find.text(
            language == 'en' ? 'Stay and retry' : 'Rester et réessayer',
          ),
        );
        await tester.pumpAndSettle();

        expect(result, isNull);
        expect(resumes, 1);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets('discard explicitly authorizes exit and keeps transfers paused', (
    tester,
  ) async {
    when(uploads.prepareForExit).thenAnswer(
      (_) async => PendingPhotoExit(pendingCount: 1, onResume: () => resumes++),
    );

    await start(tester);
    await tester.tap(find.text('Discard photos and continue'));
    await tester.pumpAndSettle();

    expect(result?.pendingCount, 1);
    expect(resumes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a changed account invalidates an open discard dialog', (
    tester,
  ) async {
    when(uploads.prepareForExit).thenAnswer(
      (_) async => PendingPhotoExit(pendingCount: 1, onResume: () => resumes++),
    );
    await start(tester);
    uid = 'uid-2';
    await tester.tap(find.text('Discard photos and continue'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(resumes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmount during queue inspection releases its pause', (
    tester,
  ) async {
    final gate = Completer<PendingPhotoExit>();
    when(uploads.prepareForExit).thenAnswer((_) => gate.future);
    await start(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete(PendingPhotoExit(pendingCount: 1, onResume: () => resumes++));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(resumes, 1);
    expect(tester.takeException(), isNull);
  });

  group('signOutAfterPhotoCheck', () {
    late _Auth auth;
    late _Push push;
    late DeviceDeregistrationDeps devices;
    bool? signedOut;

    setUp(() {
      auth = _Auth();
      push = _Push();
      final presence = _Presence();
      final liveActivity = _LiveActivity();
      final loader = _ImageLoader();
      final clients = _Clients();
      final appointments = _Appointments();
      signedOut = null;
      when(uploads.prepareForExit).thenAnswer(
        (_) async =>
            PendingPhotoExit(pendingCount: 0, onResume: () => resumes++),
      );
      when(uploads.clearPending).thenAnswer((_) async {});
      when(push.unregisterCurrentDevice).thenAnswer((_) async {});
      when(presence.unregister).thenAnswer((_) async => true);
      when(liveActivity.unregister).thenAnswer((_) async {});
      when(loader.clear).thenAnswer((_) async {});
      when(auth.signOut).thenAnswer((_) async {});
      devices = DeviceDeregistrationDeps(
        logger: AppLogger(),
        push: push,
        presence: presence,
        liveActivity: liveActivity,
        imageLoader: loader,
        imageUploads: uploads,
        clients: clients,
        appointments: appointments,
        session: session,
      );
    });

    Future<void> signOut(
      WidgetTester tester, {
      ExitTeardownGuard? guard,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                signedOut = await signOutAfterPhotoCheck(
                  context,
                  devices,
                  auth,
                  _Analytics(),
                  guard:
                      guard ??
                      (teardown) async {
                        await teardown();
                        return true;
                      },
                );
              },
              child: const Text('sign out'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('sign out'));
      await tester.pumpAndSettle();
    }

    testWidgets('a session change during deregistration never signs out', (
      tester,
    ) async {
      when(push.unregisterCurrentDevice).thenAnswer((_) async => uid = 'uid-2');

      await signOut(tester);

      expect((signedOut, resumes), (false, 1));
      verifyNever(auth.signOut);
    });

    testWidgets('a guard held by another exit returns false and releases the '
        'photo hold', (tester) async {
      await signOut(tester, guard: (_) async => false);

      expect((signedOut, resumes), (false, 1));
      verifyNever(push.unregisterCurrentDevice);
    });
  });
}
