import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The calendar's two remembered view choices: grid collapsed, agenda mode.
typedef CalendarViewState = ({bool isCollapsed, String? agendaMode});

/// Per-device memory of how the calendar was last laid out. A convenience, so
/// every read and write is best-effort: a failure leaves the defaults.
class CalendarViewPrefs {
  static const _keyCollapsed = 'calendar_grid_collapsed';
  static const _keyAgendaMode = 'calendar_agenda_mode';

  Future<CalendarViewState> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      isCollapsed: prefs.getBool(_keyCollapsed) ?? false,
      agendaMode: prefs.getString(_keyAgendaMode),
    );
  }

  Future<void> saveCollapsed({required bool isCollapsed}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCollapsed, isCollapsed);
  }

  Future<void> saveAgendaMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAgendaMode, mode);
  }
}

final calendarViewPrefsProvider = Provider<CalendarViewPrefs>(
  (ref) => CalendarViewPrefs(),
);
