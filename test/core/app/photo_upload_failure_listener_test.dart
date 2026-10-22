import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/app/photo_upload_failure_listener.dart';
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/photo_upload_expiry.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockRepo extends Mock implements AppointmentsRepository {}

class _MockUploads extends Mock implements AppointmentImageUploadService {}

void main() {
  late _MockRepo repository;
  late ProviderContainer container;
  late _MockUploads uploads;

  setUp(() {
    repository = _MockRepo();
    uploads = _MockUploads();
    when(() => uploads.acknowledgeExpiry(any())).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        appointmentsRepositoryProvider.overrideWithValue(repository),
        appointmentImageUploadProvider.overrideWithValue(uploads),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpListener(WidgetTester tester) => tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: PhotoUploadFailureListener(child: SizedBox())),
      ),
    ),
  );

  testWidgets(
    'expiry notice survives a missing listener and acknowledges only shown outcomes',
    (tester) async {
      final notices = <AppNotice>[];
      container.read(noticeServiceProvider).stream.listen(notices.add);
      container.read(photoUploadNotifierProvider).expired.value = const [
        PhotoUploadExpiry(id: 'batch', appointmentId: 'job', count: 2),
      ];
      await pumpListener(tester);
      await tester.pumpAndSettle();
      expect(
        notices.single.message,
        contains('2 photos did not finish saving'),
      );
      verify(() => uploads.acknowledgeExpiry({'batch'})).called(1);
      container.read(photoUploadNotifierProvider).expired.value = const [
        PhotoUploadExpiry(id: 'batch', appointmentId: 'job', count: 2),
      ];
      await tester.pumpAndSettle();
      expect(notices, hasLength(1));
    },
  );

  void report() => container
      .read(photoUploadNotifierProvider)
      .reportFailure('appt-1', failedCount: 1);

  testWidgets('a background upload failure surfaces wherever the user is', (
    tester,
  ) async {
    await pumpListener(tester);
    report();
    await tester.pumpAndSettle();

    expect(
      find.text('Photo upload failed. Open the appointment to retry.'),
      findsOneWidget,
    );
  });

  testWidgets('the bar offers a way back to the appointment', (tester) async {
    await pumpListener(tester);
    report();
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SnackBarAction, 'Open'), findsOneWidget);
  });

  testWidgets('a failing reopen surfaces a notice instead of crashing', (
    tester,
  ) async {
    // The Open callback is unawaited: without its guard a rules rejection or
    // an offline read escapes to the zone handler as a FATAL, with no
    // feedback at all.
    when(
      () => repository.getAppointmentById(any()),
    ).thenThrow(Exception('permission-denied'));
    final notices = <AppNotice>[];
    container.read(noticeServiceProvider).stream.listen(notices.add);

    await pumpListener(tester);
    report();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(notices.single.message, startsWith("Couldn't open the appointment"));
  });

  testWidgets('a failure reported after unmount surfaces nothing', (
    tester,
  ) async {
    // Pins the `removeListener` in dispose — a leaked listener would push a
    // bar through a State that is gone.
    await pumpListener(tester);
    await tester.pumpWidget(const SizedBox());
    report();
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('an appointment that no longer exists opens nothing', (
    tester,
  ) async {
    when(
      () => repository.getAppointmentById(any()),
    ).thenAnswer((_) async => null);

    await pumpListener(tester);
    report();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
