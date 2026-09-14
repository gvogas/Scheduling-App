import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/calendar/application/overdue_review_providers.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/navigation/widgets/app_nav_drawer.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/app_bars/app_header_pair.dart';

/// [liveRole] is the LIVE user doc, a separate question from the push-time
/// [isAdmin] argument — the admin rows are gated on both.
Widget _wrap({
  required bool isAdmin,
  TextScaler? textScaler,
  String liveRole = 'admin',
  List<AppointmentRecord>? overdue,
}) => ProviderScope(
  overrides: [
    currentUserDocProvider.overrideWith(
      (ref) => Stream.value({'role': liveRole, 'status': 'active'}),
    ),
    if (overdue != null)
      overdueOpenJobsProvider.overrideWith((ref) => Stream.value(overdue)),
  ],
  child: MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: lightTheme(),
    builder: textScaler == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
    home: Scaffold(
      appBar: AppBar(actions: const [AppHeaderPair()]),
      endDrawer: AppNavDrawer(
        isAdmin: isAdmin,
        employeeId: 'e1',
        userName: 'Jane Doe',
        email: 'jane@example.com',
      ),
      body: const SizedBox.shrink(),
    ),
  ),
);

/// Nine admin rows no longer fit the default 800x600 surface, and the drawer's
/// list only builds what is on screen.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Scheduling',
      packageName: 'net.vogas.scheduling',
      version: '1.0.3',
      buildNumber: '4',
      buildSignature: '',
    );
  });

  testWidgets('an admin drawer shows all four group headings', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_wrap(isAdmin: true));
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('PEOPLE'), findsOneWidget);
    expect(find.text('THE BUSINESS'), findsOneWidget);
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('Team'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the drop shadow sits outside the drawer, not over it', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(isAdmin: true));
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();

    // A BoxShadow blurs inward as well as outward, so a shadowed box INSIDE
    // the drawer paints a dark haze across the drawer's own surface — which
    // only shows against the light theme. It has to wrap the Drawer instead.
    final shadowed = find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          (w.decoration as BoxDecoration).boxShadow?.isNotEmpty == true,
    );
    expect(
      find.descendant(of: find.byType(Drawer), matching: shadowed),
      findsNothing,
    );
    expect(
      find.ancestor(of: find.byType(Drawer), matching: shadowed),
      findsOneWidget,
    );
  });

  testWidgets('an employee drawer hides the admin-only groups and rows', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(isAdmin: false));
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('PEOPLE'), findsNothing);
    expect(find.text('THE BUSINESS'), findsNothing);
    expect(find.text('Team'), findsNothing);
    expect(find.text('Clients'), findsNothing);
  });

  // The route argument is a push-time snapshot: a stale back stack or a deep
  // link can carry `isAdmin: true` for someone the user doc no longer says is
  // one. The live gate is what refuses them.
  testWidgets('an admin by argument whose live doc is not one gets neither', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(isAdmin: true, liveRole: 'employee'));
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();

    expect(find.text('PEOPLE'), findsNothing);
    expect(find.text('THE BUSINESS'), findsNothing);
    expect(find.text('Team'), findsNothing);
    expect(find.text('Live map'), findsNothing);
  });

  testWidgets('the drawer header shows the name and role, and a version', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(isAdmin: true));
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();

    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.textContaining('Admin'), findsOneWidget);
    expect(find.text('v1.0.3 (4)'), findsOneWidget);
  });

  testWidgets('every drawer row meets the 48px tap minimum', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_wrap(isAdmin: true));
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();

    for (final label in [
      'Calendar',
      'Day route',
      'Live map',
      'Team',
      'Clients',
      'Dashboard',
      'History',
      'Overdue jobs',
      'Settings',
    ]) {
      // Scoped to the drawer: the header pill also renders "Calendar".
      final row = find.ancestor(
        of: find.descendant(
          of: find.byType(AppNavDrawer),
          matching: find.text(label),
        ),
        matching: find.byType(InkWell),
      );
      expect(row, findsWidgets, reason: 'no row for $label');
      expect(
        tester.getSize(row.first).height,
        greaterThanOrEqualTo(48),
        reason: '$label row is below the tap minimum',
      );
    }
  });

  testWidgets('survives a 375x667 viewport at a 2.0 text scale', (
    tester,
  ) async {
    // The icon chip added 28px of leading chrome to a 284px-wide row, so the
    // label has that much less to wrap into.
    //
    // 375 wide, not the harness's usual 260: the drawer is a fixed 284px, so
    // any viewport narrower than that overflows its own header no matter what
    // this row does — a geometry no shipping phone has (narrowest is ~320dp).
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(isAdmin: true, textScaler: const TextScaler.linear(2)),
    );
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('the Overdue jobs row carries the live overdue count', (
    tester,
  ) async {
    final jobs = [
      for (var i = 0; i < 3; i++)
        AppointmentRecord(
          id: 'o$i',
          title: 'Job $i',
          startTime: DateTime(2026, 7, 1 + i, 9),
          endTime: DateTime(2026, 7, 1 + i, 11),
        ),
    ];
    _useTallViewport(tester);
    await tester.pumpWidget(_wrap(isAdmin: true, overdue: jobs));
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();

    final row = find.ancestor(
      of: find.text('Overdue jobs'),
      matching: find.byType(InkWell),
    );
    expect(find.descendant(of: row, matching: find.text('3')), findsOneWidget);
  });
}
