import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/views/agenda_sliver_list.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_month_pager.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Deterministic rendering workloads; no Firebase or customer data is needed.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('calendar rendering profile', (tester) async {
    await initializeDateFormatting('en_CA');
    await tester.pumpWidget(_wrap(const _CalendarWorkload()));
    await tester.pumpAndSettle();
    // Warm up one transition before recording the repeatable workload.
    await tester.fling(find.byType(PageView), const Offset(-350, 0), 1000);
    await tester.pumpAndSettle();
    await binding.watchPerformance(() async {
      for (var index = 0; index < 12; index++) {
        await tester.fling(find.byType(PageView), const Offset(-350, 0), 1000);
        await tester.pumpAndSettle();
      }
    }, reportKey: 'calendar_12_month_swipes');

    final day = DateTime(2026, 9, 23);
    final events = List.generate(100, (index) {
      final start = day.add(Duration(minutes: index * 10));
      return sliceFor(
        AppointmentRecord(
          id: 'fixture-$index',
          title: 'Fixture appointment $index',
          clientName: 'Synthetic customer',
          startTime: start,
          endTime: start.add(const Duration(minutes: 30)),
        ),
        day,
      )!;
    });
    await tester.pumpWidget(
      _wrap(
        CustomScrollView(
          slivers: [
            AgendaSliverList(
              events: events,
              nameMap: const {},
              colorMap: const {},
              day: day,
              onAppointmentTap: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await binding.watchPerformance(() async {
      for (var index = 0; index < 12; index++) {
        await tester.fling(
          find.byType(CustomScrollView),
          const Offset(0, -600),
          1500,
        );
        await tester.pumpAndSettle();
      }
    }, reportKey: 'agenda_100_appointments');
    binding.reportData!['device_label'] = const String.fromEnvironment(
      'PERF_DEVICE_LABEL',
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _wrap(Widget body) => MaterialApp(
  theme: lightTheme(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: body),
);

class _CalendarWorkload extends StatefulWidget {
  const _CalendarWorkload();

  @override
  State<_CalendarWorkload> createState() => _CalendarWorkloadState();
}

class _CalendarWorkloadState extends State<_CalendarWorkload> {
  DateTime month = DateTime(2026, 9);

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: CalendarMonthPager(
      month: month,
      selectedDay: DateTime(2026, 9, 23),
      today: DateTime(2026, 9, 23),
      onDaySelected: (_) {},
      onMonthChanged: (value) => setState(() => month = value),
      dotColorsFor: (_) => const [Colors.blue, Colors.green, Colors.orange],
      countFor: (_) => 8,
    ),
  );
}
