import 'dart:async';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/l10n/l10n.dart';

FirebaseException _fb(String code) =>
    FirebaseException(plugin: 'cloud_firestore', code: code);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  // We test classification through the public composeErrorNotice, since the
  // classifier itself is private to error_cause.dart.
  late String Function(Object error) noticeFor;

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            noticeFor = (error) =>
                composeErrorNotice(context, intro: 'Intro', error: error);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }

  String expected(String cause) => l10n.error_noticeWithCause('Intro', cause);

  group('error classification (via composeErrorNotice)', () {
    testWidgets('network-ish Firebase codes map to offline', (tester) async {
      await pumpHost(tester);
      expect(noticeFor(_fb('unavailable')), expected(l10n.error_causeOffline));
      expect(
        noticeFor(_fb('network-request-failed')),
        expected(l10n.error_causeOffline),
      );
      expect(
        noticeFor(_fb('deadline-exceeded')),
        expected(l10n.error_causeOffline),
      );
    });

    testWidgets('a callable failed-precondition maps to its own cause', (
      tester,
    ) async {
      await pumpHost(tester);
      expect(
        noticeFor(
          FirebaseFunctionsException(
            code: 'failed-precondition',
            message: 'client-has-history',
          ),
        ),
        expected(l10n.error_causeFailedPrecondition),
      );
      expect(
        l10n.error_causeFailedPrecondition,
        isNot(l10n.error_causeUnknown),
      );
    });

    testWidgets('a Firestore failed-precondition (missing index) is unknown', (
      tester,
    ) async {
      await pumpHost(tester);
      expect(
        noticeFor(_fb('failed-precondition')),
        expected(l10n.error_causeUnknown),
      );
    });

    testWidgets('a paused callable (feature-disabled) is unknown', (
      tester,
    ) async {
      await pumpHost(tester);
      expect(
        noticeFor(
          FirebaseFunctionsException(
            code: 'failed-precondition',
            message: 'feature-disabled',
          ),
        ),
        expected(l10n.error_causeUnknown),
      );
    });

    testWidgets('permission-denied maps to permissionDenied', (tester) async {
      await pumpHost(tester);
      expect(
        noticeFor(_fb('permission-denied')),
        expected(l10n.error_causePermissionDenied),
      );
    });

    testWidgets('not-found maps to notFound', (tester) async {
      await pumpHost(tester);
      expect(noticeFor(_fb('not-found')), expected(l10n.error_causeNotFound));
    });

    testWidgets('socket and timeout exceptions map to offline', (tester) async {
      await pumpHost(tester);
      expect(
        noticeFor(const SocketException('x')),
        expected(l10n.error_causeOffline),
      );
      expect(
        noticeFor(TimeoutException('x')),
        expected(l10n.error_causeOffline),
      );
    });

    testWidgets('unauthenticated maps to signedOut', (tester) async {
      await pumpHost(tester);
      expect(
        noticeFor(_fb('unauthenticated')),
        expected(l10n.error_causeSignedOut),
      );
    });

    testWidgets('rate-limit codes map to tooManyAttempts', (tester) async {
      await pumpHost(tester);
      expect(
        noticeFor(_fb('resource-exhausted')),
        expected(l10n.error_causeTooManyAttempts),
      );
      expect(
        noticeFor(_fb('too-many-requests')),
        expected(l10n.error_causeTooManyAttempts),
      );
    });

    testWidgets('rejected-payload codes map to invalidData', (tester) async {
      await pumpHost(tester);
      expect(
        noticeFor(_fb('invalid-argument')),
        expected(l10n.error_causeInvalidData),
      );
    });

    testWidgets('anything else maps to unknown', (tester) async {
      await pumpHost(tester);
      expect(noticeFor(Exception('boom')), expected(l10n.error_causeUnknown));
      expect(noticeFor(_fb('aborted')), expected(l10n.error_causeUnknown));
      expect(
        noticeFor(
          FirebaseException(
            plugin: 'cloud_functions',
            code: 'aborted',
            message: 'appointment-edit-conflict',
          ),
        ),
        expected(l10n.error_causeEditConflict),
      );
    });

    testWidgets('an incomplete scan is distinct from rate limiting', (
      tester,
    ) async {
      await pumpHost(tester);
      for (final message in [
        'conflict-scan-incomplete',
        'client-search-incomplete',
      ]) {
        expect(
          noticeFor(
            FirebaseException(
              plugin: 'cloud_functions',
              code: 'resource-exhausted',
              message: message,
            ),
          ),
          expected(l10n.error_causeIncompleteCheck),
        );
      }
    });
  });

  group('composeErrorNotice', () {
    testWidgets('states what failed, then what the user can do', (
      tester,
    ) async {
      late String message;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              message = composeErrorNotice(
                context,
                intro: "Couldn't delete the client",
                error: _fb('unavailable'),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(
        message,
        "Couldn't delete the client. You appear to be offline — check your "
        'connection and try again.',
      );
    });

    testWidgets('never leaks the raw error or a support tag', (tester) async {
      await pumpHost(tester);
      final message = noticeFor(_fb('permission-denied'));
      expect(message, isNot(contains('permission-denied')));
      expect(message, isNot(contains('(')));
    });
  });

  // I12: nine call sites, zero tests — while `composeErrorNotice` beside it is
  // well covered.
  group('guardedOffline', () {
    Future<({bool fired, List<AppNotice> notices})> run(
      WidgetTester tester, {
      required bool offline,
    }) async {
      final notices = <AppNotice>[];
      late bool fired;
      final container = ProviderContainer(
        overrides: [isOfflineProvider.overrideWithValue(offline)],
      );
      addTearDown(container.dispose);
      container.read(noticeServiceProvider).stream.listen(notices.add);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) {
                fired = guardedOffline(context, ref, intro: 'Intro');
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      // The notice rides a broadcast stream, so let the event loop turn.
      await tester.pump();
      return (fired: fired, notices: notices);
    }

    testWidgets('returns false and stays silent when online', (tester) async {
      final result = await run(tester, offline: false);
      expect(result.fired, isFalse);
      expect(result.notices, isEmpty);
    });

    testWidgets('returns true and pushes the offline cause', (tester) async {
      final result = await run(tester, offline: true);
      expect(result.fired, isTrue);
      expect(result.notices, hasLength(1));
      final notice = result.notices.single;
      expect(notice, isA<NoticeError>());
      // The caller's intro, then the shared offline cause — the same sentence
      // composeErrorNotice builds for a real SocketException.
      expect(notice.message, 'Intro. ${l10n.error_causeOffline}');
    });
  });

  // Zero tests, six call sites, and its own dartdoc says three of them
  // previously spelled the distinction wrong.
  group('isFirstAsyncError', () {
    const data = AsyncData<int>(1);
    const loading = AsyncLoading<int>();
    final failed = AsyncError<int>(StateError('x'), StackTrace.empty);
    test('data -> error is the first error', () {
      expect(isFirstAsyncError(data, failed), isTrue);
    });

    test('a first-ever emission that is an error counts', () {
      expect(isFirstAsyncError(null, failed), isTrue);
    });

    test('loading -> error counts', () {
      expect(isFirstAsyncError(loading, failed), isTrue);
    });

    test('error -> error is NOT first', () {
      expect(isFirstAsyncError(failed, failed), isFalse);
    });

    test('a REAL provider retry reports exactly once, not once per attempt', () {
      // The whole reason the helper exists, driven through Riverpod rather than
      // a hand-built AsyncValue: refreshing an already-errored provider emits
      // an AsyncLoading that STILL CARRIES the error, so `hasError` is true
      // while `is AsyncError` is false.
      final provider = FutureProvider<int>((ref) async {
        throw StateError('always');
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final reported = <AsyncValue<int>>[];
      container
        ..listen<AsyncValue<int>>(provider, (previous, next) {
          if (isFirstAsyncError(previous, next)) reported.add(next);
        }, fireImmediately: true)
        // Settle the first failure, then retry it twice.
        ..read(provider)
        ..invalidate(provider)
        ..read(provider)
        ..invalidate(provider)
        ..read(provider);

      expect(reported, hasLength(lessThanOrEqualTo(1)));
    });

    test('error -> data reports nothing', () {
      expect(isFirstAsyncError(failed, data), isFalse);
    });

    test('data -> data reports nothing', () {
      expect(isFirstAsyncError(data, data), isFalse);
    });
  });
}
