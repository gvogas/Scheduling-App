import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/policies/history_search_policy.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

import '../../../../fixtures/shared/shared_fixture.dart';

bool _matches(AppointmentRecord appointment, String query) =>
    historyEntryMatches(
      historyEntryOf(appointment),
      queryText: ClientSearchPolicy.normalize(query),
      queryDigits: ClientSearchPolicy.digitsOnly(query),
    );

Map<String, dynamic> _rawDoc() => <String, dynamic>{
  'title': 'Job',
  'clientName': 'Marie Tremblay',
  'clientPhone': '5145554321',
  'employeeNames': <dynamic>['Marc Dubois'],
};

void main() {
  // Shared with the jest suite: test/fixtures/shared/search_tokens.json.
  group('historyEntryMatches client/employee seam', () {
    final seam =
        loadSharedFixture('search_tokens.json')['historySeam']
            as Map<String, dynamic>;
    final record = seam['record'] as Map<String, dynamic>;
    final appointment = AppointmentRecord(
      id: 'a1',
      startTime: DateTime(2026, 9, 5, 9),
      endTime: DateTime(2026, 9, 5, 11),
      clientName: record['clientName'] as String,
      clientPhone: record['clientPhone'] as String,
      employeeNames: (record['employeeNames'] as List).cast<String>(),
    );

    for (final c in sharedCases(seam, 'cases')) {
      test(c['name'] as String, () {
        expect(_matches(appointment, c['query'] as String), c['expect']);
      });
    }
  });

  group('matchHistoryDocs', () {
    test('reads the seam off the raw map the same way', () {
      final matched = matchHistoryDocs(
        HistorySearchScan(
          docs: [(id: 'a1', data: _rawDoc())],
          query: 'tremblay marc',
        ),
      );
      expect(matched, isEmpty);
    });

    test('keeps a document that matches one field outright', () {
      final matched = matchHistoryDocs(
        HistorySearchScan(docs: [(id: 'a1', data: _rawDoc())], query: 'dubois'),
      );
      expect(matched.map((a) => a.id), ['a1']);
    });
  });
}
