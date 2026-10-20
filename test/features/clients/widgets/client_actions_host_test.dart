import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/application/client_form_controller.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_failure.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/views/client_actions_host.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The archive/delete flow shared by the clients list and the client detail.
/// Three ordering rules live here in ~40 lines with no compile-time
/// protection, and both destructive client paths route through them:
///   1. a reentrancy-skipped write surfaces NOTHING — no success, no error
///   2. the typed `has history` branch wins over the generic cause notice
///   3. delete confirms FIRST, and the offline guard runs after the dialog
const _client = ClientRecord(id: 'c1', name: 'Acme Plumbing');

class _FakeRepo implements ClientsRepository {
  _FakeRepo({this.onDelete, this.onArchive});

  final Future<void> Function()? onDelete;
  final Future<void> Function()? onArchive;

  final List<String> calls = [];

  @override
  Future<void> deleteClient(String id) async {
    calls.add('delete:$id');
    if (onDelete != null) await onDelete!();
  }

  @override
  Future<void> setClientArchived(String id, {required bool archived}) async {
    calls.add('archive:$id:$archived');
    if (onArchive != null) await onArchive!();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not stubbed');
}

/// Minimal host that exercises the mixin and records its callbacks.
class _Host extends ConsumerStatefulWidget {
  const _Host({required this.log});

  final List<String> log;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> with ClientActionsHost<_Host> {
  @override
  void onClientArchived(ClientRecord client, {required bool archived}) =>
      widget.log.add('archived:${client.id}:$archived');

  @override
  void onClientDeleted(ClientRecord client) =>
      widget.log.add('deleted:${client.id}');

  @override
  Widget build(BuildContext context) => Scaffold(
    // Mirrors ClientDetailView, which watches this for its busy state. The
    // watch is what keeps the autoDispose notifier alive between reads — and
    // therefore what makes the reentrancy guard hold at all.
    body: Column(
      key: ValueKey(ref.watch(clientFormControllerProvider)),
      children: [
        TextButton(
          onPressed: () => archiveClient(_client),
          child: const Text('archive'),
        ),
        TextButton(
          onPressed: () => confirmDeleteClient(_client),
          child: const Text('delete'),
        ),
      ],
    ),
  );
}

void main() {
  late List<String> log;
  late List<AppNotice> notices;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    log = [];
    notices = [];
  });

  Future<_FakeRepo> pump(
    WidgetTester tester, {
    Future<void> Function()? onDelete,
    Future<void> Function()? onArchive,
  }) async {
    final repo = _FakeRepo(onDelete: onDelete, onArchive: onArchive);
    final container = ProviderContainer(
      overrides: [clientsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    container.read(noticeServiceProvider).stream.listen(notices.add);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          home: _Host(log: log),
        ),
      ),
    );
    return repo;
  }

  group('archive', () {
    testWidgets('archives, notifies, and calls back', (tester) async {
      final repo = await pump(tester);

      await tester.tap(find.text('archive'));
      await tester.pumpAndSettle();

      expect(repo.calls, ['archive:c1:true']);
      expect(log, ['archived:c1:true']);
      expect(notices.single, isA<NoticeSuccess>());
    });

    testWidgets('the success notice carries an Undo that reverses the toggle', (
      tester,
    ) async {
      // The one action the rules allow on a notice: archive/unarchive is a
      // symmetric toggle, and a full swipe was the one destructive gesture
      // with no second chance.
      final repo = await pump(tester);

      await tester.tap(find.text('archive'));
      await tester.pumpAndSettle();
      final action = notices.single.action;
      expect(action?.label, 'Undo');

      await action!.onPressed();
      await tester.pumpAndSettle();

      expect(repo.calls, ['archive:c1:true', 'archive:c1:false']);
      // The host hears the reversal too, so an in-place list removal is undone.
      expect(log, ['archived:c1:true', 'archived:c1:false']);
      expect(notices, hasLength(1), reason: 'an undo raises no second notice');
    });

    testWidgets('a failure notices and does NOT call back', (tester) async {
      await pump(tester, onArchive: () async => throw Exception('boom'));

      await tester.tap(find.text('archive'));
      await tester.pumpAndSettle();

      expect(log, isEmpty);
      expect(notices.single, isA<NoticeError>());
      // The intro names the operation that failed; the CLI-ARCH tag lives in
      // the log line only, never in what the admin reads.
      expect(
        notices.single.message,
        startsWith("Couldn't archive the client."),
      );
      expect(notices.single.message, isNot(contains('CLI-ARCH')));
    });
  });

  group('delete', () {
    testWidgets('does nothing until the dialog is confirmed', (tester) async {
      final repo = await pump(tester);

      await tester.tap(find.text('delete'));
      await tester.pumpAndSettle();
      expect(repo.calls, isEmpty, reason: 'confirm dialog not answered yet');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(repo.calls, isEmpty);
      expect(log, isEmpty);
      expect(notices, isEmpty);
    });

    testWidgets('deletes, notifies, and calls back once confirmed', (
      tester,
    ) async {
      final repo = await pump(tester);

      await tester.tap(find.text('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();

      expect(repo.calls, ['delete:c1']);
      expect(log, ['deleted:c1']);
      expect(notices.single, isA<NoticeSuccess>());
    });

    testWidgets('a client with history gets the ACTIONABLE message', (
      tester,
    ) async {
      // The typed branch must run before the generic composer: "archive it
      // instead" names the actual remedy, where the generic cause can only
      // offer "try again".
      await pump(
        tester,
        onDelete: () async => throw const ClientsFailureHasHistory(),
      );

      await tester.tap(find.text('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();

      expect(log, isEmpty);
      expect(notices.single, isA<NoticeError>());
      expect(
        notices.single.message,
        "This client has job history, so it can't be deleted. Archive it "
        'instead.',
      );
    });

    testWidgets('a second tap mid-flight is skipped and surfaces nothing', (
      tester,
    ) async {
      // The reentrancy guard returns ClientDeleteBusy, which must produce
      // NEITHER a success nor an error notice — a skipped write did not fail.
      final gate = Completer<void>();
      final repo = await pump(tester, onDelete: () => gate.future);

      await tester.tap(find.text('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pump();

      // Second run, while the first is still awaiting the repository.
      await tester.tap(find.text('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pump();

      gate.complete();
      await tester.pumpAndSettle();

      expect(repo.calls, ['delete:c1'], reason: 'the second call was skipped');
      expect(log, ['deleted:c1']);
      expect(notices, hasLength(1));
      expect(notices.single, isA<NoticeSuccess>());
    });

    testWidgets('an untyped failure falls back to the cause notice', (
      tester,
    ) async {
      await pump(tester, onDelete: () async => throw Exception('boom'));

      await tester.tap(find.text('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();

      expect(log, isEmpty);
      expect(
        notices.single.message,
        "Couldn't delete the client. Please try again in a moment.",
      );
    });
  });
}
