import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The calendar's two remembered view choices: grid collapsed, agenda mode.
typedef CalendarViewState = ({bool isCollapsed, String? agendaMode});

/// Per-device memory of how the calendar was last laid out. A convenience, so
/// every read and write is best-effort: a failure is logged and leaves the
/// defaults.
class CalendarViewPrefs {
  CalendarViewPrefs({AppLogger? logger}) : _logger = logger ?? AppLogger();

  static const _keyCollapsed = 'calendar_grid_collapsed';
  static const _keyAgendaMode = 'calendar_agenda_mode';

  final AppLogger _logger;

  Future<CalendarViewState> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (
        isCollapsed: prefs.getBool(_keyCollapsed) ?? false,
        agendaMode: prefs.getString(_keyAgendaMode),
      );
    } catch (e, st) {
      _logger.warn('SETTINGS calendar view prefs read failed', e, st);
      return (isCollapsed: false, agendaMode: null);
    }
  }

  Future<void> saveCollapsed({required bool isCollapsed}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyCollapsed, isCollapsed);
    } catch (e, st) {
      _logger.warn('SETTINGS calendar view prefs write failed', e, st);
    }
  }

  Future<void> saveAgendaMode(String mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAgendaMode, mode);
    } catch (e, st) {
      _logger.warn('SETTINGS calendar view prefs write failed', e, st);
    }
  }
}

final calendarViewPrefsProvider = Provider<CalendarViewPrefs>(
  (ref) => CalendarViewPrefs(logger: ref.read(loggerProvider)),
);
