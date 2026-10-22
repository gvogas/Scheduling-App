import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/data/calendar_view_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockLogger extends Mock implements AppLogger {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('nothing stored loads the defaults', () async {
    final state = await CalendarViewPrefs().load();
    expect(state.isCollapsed, isFalse);
    expect(state.agendaMode, isNull);
  });

  test('saved collapse and agenda mode round-trip', () async {
    final prefs = CalendarViewPrefs();
    await prefs.saveCollapsed(isCollapsed: true);
    await prefs.saveAgendaMode('week');

    final state = await CalendarViewPrefs().load();
    expect(state.isCollapsed, isTrue);
    expect(state.agendaMode, 'week');
  });

  test('an unknown stored mode is returned verbatim for the caller', () async {
    SharedPreferences.setMockInitialValues({
      'calendar_agenda_mode': 'fortnight',
    });
    final state = await CalendarViewPrefs().load();
    // The screen maps it through `asNameMap()[...]`, so unknown falls to day.
    expect(state.agendaMode, 'fortnight');
  });

  test(
    'a plugin failure is logged under SETTINGS and leaves defaults',
    () async {
      // A non-bool under the bool key makes the typed read throw.
      SharedPreferences.setMockInitialValues({
        'calendar_grid_collapsed': 'yes',
      });
      final logger = _MockLogger();
      final state = await CalendarViewPrefs(logger: logger).load();

      expect(state.isCollapsed, isFalse);
      expect(state.agendaMode, isNull);
      verify(
        () => logger.warn(any(that: startsWith('SETTINGS')), any(), any()),
      ).called(1);
    },
  );
}
