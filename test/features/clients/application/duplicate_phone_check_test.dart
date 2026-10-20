import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/utils/debouncer.dart';
import 'package:scheduling/features/clients/application/duplicate_phone_check.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';

/// Only a client's OWN number is a duplicate — a contact's, or a longer number
/// that merely contains the digits, is not — and a dead callable must never
/// stop an admin adding a client.
class _FakeRepo implements ClientsRepository {
  _FakeRepo(this.onFile, {this.throws = false});

  final List<ClientRecord> onFile;
  final bool throws;
  final List<String> queries = [];

  @override
  Future<List<ClientRecord>> searchClients(
    String query, {
    ClientsFilter filter = const ClientsFilterAll(),
  }) async {
    queries.add(query);
    if (throws) throw Exception('callable down');
    return onFile;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SilentLogger extends AppLogger {
  final warned = <String>[];

  @override
  void warn(String message, [Object? error, StackTrace? stack]) =>
      warned.add(message);
}

const _jane = ClientRecord(id: 'x1', name: 'Jane Doe', phone: '(514) 555-0000');

void main() {
  late TextEditingController phone;
  late _SilentLogger logger;

  setUp(() {
    phone = TextEditingController();
    logger = _SilentLogger();
  });

  tearDown(() => phone.dispose());

  DuplicatePhoneCheck check(_FakeRepo repo) =>
      DuplicatePhoneCheck(repository: repo, logger: logger, phone: phone);

  void settle(FakeAsync async) {
    async
      ..elapse(kSearchDebounce + const Duration(milliseconds: 1))
      ..flushMicrotasks();
  }

  test('a number already on file is a match that blocks the save', () {
    fakeAsync((async) {
      final repo = _FakeRepo(const [_jane]);
      final sut = check(repo);
      phone.text = '(514) 555-0000';
      settle(async);

      expect(sut.match?.id, 'x1');
      expect(sut.blocksSave, isTrue);
      expect(repo.queries, ['5145550000']);
      sut.dispose();
    });
  });

  test('Use anyway releases the block until the number changes', () {
    fakeAsync((async) {
      final sut = check(_FakeRepo(const [_jane]));
      phone.text = '5145550000';
      settle(async);
      sut.useAnyway();
      expect(sut.blocksSave, isFalse);

      phone.text = '5145550001';
      settle(async);

      expect(sut.acknowledged, isFalse);
      sut.dispose();
    });
  });

  test('a longer number that merely contains the digits is no duplicate', () {
    fakeAsync((async) {
      final sut = check(_FakeRepo(const [_jane]));
      phone.text = '5145550';
      settle(async);

      expect(sut.match, isNull);
      sut.dispose();
    });
  });

  test('a NANP leading 1 on file still matches the ten typed digits', () {
    fakeAsync((async) {
      final sut = check(
        _FakeRepo(const [
          ClientRecord(id: 'x2', name: 'Jane', phone: '+1 514 555 0000'),
        ]),
      );
      phone.text = '5145550000';
      settle(async);

      expect(sut.match?.id, 'x2');
      sut.dispose();
    });
  });

  test('fewer than seven digits never reaches the callable', () {
    fakeAsync((async) {
      final repo = _FakeRepo(const [_jane]);
      final sut = check(repo);
      phone.text = '514555';
      settle(async);

      expect(repo.queries, isEmpty);
      sut.dispose();
    });
  });

  test('a failed lookup fails OPEN and is logged', () {
    fakeAsync((async) {
      final sut = check(_FakeRepo(const [], throws: true));
      phone.text = '5145550000';
      settle(async);

      expect(sut.blocksSave, isFalse);
      expect(logger.warned.single, startsWith('CLI-SEARCH'));
      sut.dispose();
    });
  });

  test('ensureChecked runs the pending lookup at once', () {
    fakeAsync((async) {
      final repo = _FakeRepo(const [_jane]);
      final sut = check(repo);
      phone.text = '5145550000';
      // Add tapped inside the debounce window.
      var settled = false;
      sut.ensureChecked().then((_) => settled = true);
      async.flushMicrotasks();

      expect(settled, isTrue);
      expect(sut.blocksSave, isTrue);
      expect(repo.queries, ['5145550000'], reason: 'one lookup, not two');
      sut.dispose();
    });
  });
}
