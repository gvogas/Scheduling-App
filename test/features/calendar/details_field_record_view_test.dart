import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/images/image_picker_service.dart';
import 'package:scheduling/core/images/images_providers.dart';
import 'package:scheduling/core/notices/notice_listener.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/field_note.dart';
import 'package:scheduling/features/calendar/widgets/views/details_field_record_view.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockRepo extends Mock implements AppointmentsRepository {}

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockPicker extends Mock implements ImagePickerService {}

class _MockUploader extends Mock implements AppointmentImageUploadService {}

const _identity = (role: 'employee', docId: 'e1');

final _job = AppointmentRecord(
  id: 'a1',
  title: 'Leak fix',
  startTime: DateTime(2026, 9, 7, 9),
  endTime: DateTime(2026, 9, 7, 10),
  employeeIds: const ['e1'],
  employeeNames: const ['Marc Tremblay'],
);

/// The crew's only write surface. A double tap posts twice into an append-only
/// collection they can neither edit nor delete, so the reentrancy guard is the
/// thing standing between a glove-tapped button and a duplicated record.
void main() {
  late _MockRepo repository;
  late _MockEmployeesRepo employees;
  late _MockPicker picker;
  late _MockUploader uploader;

  setUp(() {
    repository = _MockRepo();
    employees = _MockEmployeesRepo();
    picker = _MockPicker();
    uploader = _MockUploader();
    when(
      () => repository.fetchFieldNotes(any()),
    ).thenAnswer((_) async => (notes: const <FieldNote>[], truncated: false));
    when(
      () => repository.appendFieldNote(
        appointmentId: any(named: 'appointmentId'),
        text: any(named: 'text'),
        authorId: any(named: 'authorId'),
        authorName: any(named: 'authorName'),
      ),
    ).thenAnswer((_) async {});
    // The photo cap reads the details controller, which seeds from these.
    when(
      () => repository.onLocalWrite,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => repository.fetchAppointmentPictures(any()),
    ).thenAnswer((_) async => const []);
    when(
      employees.watchEmployees,
    ).thenAnswer((_) => Stream.value(const <EmployeeRecord>[]));
  });

  List<Override> overrides({
    ActiveUserIdentity? identity = _identity,
    bool offline = false,
    Stream<String?>? uids,
  }) => [
    authUidProvider.overrideWith(
      (ref) => uids ?? Stream<String?>.value('uid-1'),
    ),
    appointmentsRepositoryProvider.overrideWithValue(repository),
    employeesRepositoryProvider.overrideWithValue(employees),
    imagePickerProvider.overrideWithValue(picker),
    appointmentImageUploadProvider.overrideWithValue(uploader),
    activeUserIdentityProvider.overrideWith((ref) async => identity),
    currentUserNameProvider.overrideWithValue('Marc Tremblay'),
    isOfflineProvider.overrideWithValue(offline),
  ];

  /// [container] lets a test dismiss and reopen the view under ONE provider
  /// tree, the way a sheet closes and reopens inside the running app; [body]
  /// is what stands in for the dismissed sheet.
  Future<void> pump(
    WidgetTester tester, {
    ActiveUserIdentity? identity = _identity,
    bool offline = false,
    ProviderContainer? container,
    Widget? body,
  }) async {
    final child = _App(
      body: body ?? DetailsFieldRecordView(appointment: _job),
    );
    await tester.pumpWidget(
      container == null
          ? ProviderScope(
              overrides: overrides(identity: identity, offline: offline),
              child: child,
            )
          : UncontrolledProviderScope(container: container, child: child),
    );
    await tester.pumpAndSettle();
  }

  Future<void> typeNote(WidgetTester tester, [String text = 'Valve swapped']) =>
      tester.enterText(find.byType(TextField), text);

  Finder postButton() => find.byType(FilledButton);

  /// Runs the notice banner out so its auto-dismiss timer cannot outlive the
  /// widget tree.
  Future<void> settleNotices(WidgetTester tester) async {
    await tester.pump(AppMotion.noticeCycle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  VerificationResult verifyPosts() => verify(
    () => repository.appendFieldNote(
      appointmentId: any(named: 'appointmentId'),
      text: any(named: 'text'),
      authorId: any(named: 'authorId'),
      authorName: any(named: 'authorName'),
    ),
  );

  void verifyNoPost() => verifyNever(
    () => repository.appendFieldNote(
      appointmentId: any(named: 'appointmentId'),
      text: any(named: 'text'),
      authorId: any(named: 'authorId'),
      authorName: any(named: 'authorName'),
    ),
  );

  void stubPick(List<File> files) {
    when(() => picker.pickMultiImages()).thenAnswer((_) async => files);
    when(
      () => uploader.enqueuePhotos(
        appointmentId: any(named: 'appointmentId'),
        newImages: any(named: 'newImages'),
      ),
    ).thenAnswer((_) async {});
  }

  Future<void> addFromGallery(WidgetTester tester) async {
    await tester.tap(find.text('Add photos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from Gallery'));
    await tester.pumpAndSettle();
  }

  testWidgets('an empty note cannot be posted at all', (tester) async {
    await pump(tester);
    expect(tester.widget<FilledButton>(postButton()).onPressed, isNull);
  });

  testWidgets('a double tap posts the note ONCE', (tester) async {
    // No pump between the taps: the second tap runs against the button the
    // first tap has not yet had a frame to disable, which is exactly the race
    // a gloved thumb produces and the only one `_isSaving` can catch.
    final held = Completer<void>();
    when(
      () => repository.appendFieldNote(
        appointmentId: any(named: 'appointmentId'),
        text: any(named: 'text'),
        authorId: any(named: 'authorId'),
        authorName: any(named: 'authorName'),
      ),
    ).thenAnswer((_) => held.future);

    await pump(tester);
    await typeNote(tester);
    await tester.pump();

    await tester.tap(postButton());
    await tester.tap(postButton());
    await tester.pump();

    verifyPosts().called(1);

    held.complete();
    await tester.pumpAndSettle();
    await settleNotices(tester);
  });

  testWidgets('the note is filed under the caller own doc id', (tester) async {
    await pump(tester);
    await typeNote(tester);
    await tester.pump();

    await tester.tap(postButton());
    await tester.pumpAndSettle();

    final call = verify(
      () => repository.appendFieldNote(
        appointmentId: captureAny(named: 'appointmentId'),
        text: captureAny(named: 'text'),
        // The rules pin this to the caller's OWN doc id, so a note can never
        // be filed under a colleague's name.
        authorId: captureAny(named: 'authorId'),
        authorName: captureAny(named: 'authorName'),
      ),
    )..called(1);
    expect(call.captured, ['a1', 'Valve swapped', 'e1', 'Marc Tremblay']);
    await settleNotices(tester);
  });

  testWidgets('a successful post clears the box and confirms', (tester) async {
    await pump(tester);
    await typeNote(tester);
    await tester.pump();

    await tester.tap(postButton());
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('Note added'), findsOneWidget);
    await settleNotices(tester);
  });

  testWidgets('text typed while a note posts survives the post', (
    tester,
  ) async {
    final held = Completer<void>();
    when(
      () => repository.appendFieldNote(
        appointmentId: any(named: 'appointmentId'),
        text: any(named: 'text'),
        authorId: any(named: 'authorId'),
        authorName: any(named: 'authorName'),
      ),
    ).thenAnswer((_) => held.future);

    await pump(tester);
    await typeNote(tester);
    await tester.pump();
    await tester.tap(postButton());
    await tester.pump();
    await typeNote(tester, 'Valve swapped and the filter');

    held.complete();
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'and the filter',
      reason: 'the posted text must not stay behind to post twice',
    );
    await settleNotices(tester);
  });

  testWidgets('an unresolved identity writes nothing and says so', (
    tester,
  ) async {
    // Nothing else knows who the author is, and the rules refuse a note whose
    // authorId is not the caller — so a blank one is a permission-denied.
    await pump(tester, identity: null);
    await typeNote(tester);
    await tester.pump();

    await tester.tap(postButton());
    await tester.pumpAndSettle();

    verifyNoPost();
    expect(find.textContaining("Couldn't save your notes"), findsOneWidget);
    await settleNotices(tester);
  });

  testWidgets('offline is refused before the write, not after it', (
    tester,
  ) async {
    // An awaited Firestore write only resolves on server ack, so without the
    // guard Post spins until the crew is back in signal.
    await pump(tester, offline: true);
    await typeNote(tester);
    await tester.pump();

    await tester.tap(postButton());
    await tester.pumpAndSettle();

    verifyNoPost();
    expect(find.textContaining('offline'), findsOneWidget);
    await settleNotices(tester);
  });

  testWidgets('a failed post surfaces a notice and re-enables the button', (
    tester,
  ) async {
    when(
      () => repository.appendFieldNote(
        appointmentId: any(named: 'appointmentId'),
        text: any(named: 'text'),
        authorId: any(named: 'authorId'),
        authorName: any(named: 'authorName'),
      ),
    ).thenThrow(Exception('nope'));

    await pump(tester);
    await typeNote(tester);
    await tester.pump();

    await tester.tap(postButton());
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't save your notes"), findsOneWidget);
    expect(
      tester.widget<FilledButton>(postButton()).onPressed,
      isNotNull,
      reason: 'the typed note is still there, so it must stay postable',
    );
    await settleNotices(tester);
  });

  group('the draft survives a dismissed sheet', () {
    ProviderContainer makeContainer({Stream<String?>? uids}) {
      final container = ProviderContainer(overrides: overrides(uids: uids));
      addTearDown(container.dispose);
      return container;
    }

    testWidgets('a different person signing in never sees the draft', (
      tester,
    ) async {
      // Shared phone: tech A's unposted note must not pre-fill tech B's box.
      final uids = StreamController<String?>();
      addTearDown(uids.close);
      // The app keeps the uid stream listened for the whole session.
      final container = makeContainer(uids: uids.stream)
        ..listen(authUidProvider, (_, _) {});
      uids.add('uid-a');
      await pump(tester, container: container);
      await typeNote(tester, 'Half typed');
      await tester.pump();
      await pump(tester, container: container, body: const SizedBox());

      uids.add('uid-b');
      await tester.pumpAndSettle();
      await pump(tester, container: container);

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    });

    testWidgets('a typed note is restored when the view is rebuilt', (
      tester,
    ) async {
      // A scrim tap or drag dismisses the details sheet with no guard, and the
      // local TextEditingController went with it.
      final container = makeContainer();
      await pump(tester, container: container);
      await typeNote(tester, 'Half typed');
      await tester.pump();

      await pump(tester, container: container, body: const SizedBox());
      await pump(tester, container: container);

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Half typed',
      );
      expect(tester.widget<FilledButton>(postButton()).onPressed, isNotNull);
    });

    testWidgets('posting clears it, so the reopened box is empty', (
      tester,
    ) async {
      final container = makeContainer();
      await pump(tester, container: container);
      await typeNote(tester);
      await tester.pump();
      await tester.tap(postButton());
      await tester.pumpAndSettle();
      await settleNotices(tester);

      await pump(tester, container: container, body: const SizedBox());
      await pump(tester, container: container);

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    });
  });

  group('photos', () {
    testWidgets('added offline, they say they will upload on reconnect', (
      tester,
    ) async {
      // Photos are deliberately NOT offline-guarded (they queue), but the only
      // cue was the strip's pending badge, which read as a stall.
      stubPick([File('/tmp/one.jpg'), File('/tmp/two.jpg')]);
      await pump(tester, offline: true);

      await addFromGallery(tester);

      verify(
        () => uploader.enqueuePhotos(
          appointmentId: 'a1',
          newImages: any(named: 'newImages'),
        ),
      ).called(1);
      expect(
        find.text("2 photos will upload when you're back online."),
        findsOneWidget,
      );
      await settleNotices(tester);
    });

    testWidgets('added online, they get no queue notice', (tester) async {
      stubPick([File('/tmp/one.jpg')]);
      await pump(tester);

      await addFromGallery(tester);

      expect(find.textContaining('will upload'), findsNothing);
    });
  });
}

class _App extends StatelessWidget {
  const _App({required this.body});

  final Widget body;

  @override
  Widget build(BuildContext context) {
    final navigatorKey = GlobalKey<NavigatorState>();
    return MaterialApp(
      navigatorKey: navigatorKey,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => NoticeListener(
        navigatorKey: navigatorKey,
        child: child ?? const SizedBox.shrink(),
      ),
      // The identity is an autoDispose FutureProvider that the view only
      // `ref.read`s; in the app it is already warm because the shell watches
      // it, so the harness has to hold it open the same way.
      home: Consumer(
        builder: (context, ref, _) {
          ref.watch(activeUserIdentityProvider);
          return Scaffold(body: SingleChildScrollView(child: body));
        },
      ),
    );
  }
}
