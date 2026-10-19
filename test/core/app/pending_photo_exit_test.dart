import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/app/pending_photo_exit.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/l10n/l10n.dart';

class _Uploads extends Mock implements AppointmentImageUploadService {}

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
}
