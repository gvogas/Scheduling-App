import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/employees/application/employee_schedule_providers.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';
import 'package:scheduling/features/employees/widgets/cards/employee_card.dart';
import 'package:scheduling/features/employees/widgets/cards/pending_invite_tile.dart';
import 'package:scheduling/features/employees/widgets/fields/credential_line.dart';
import 'package:scheduling/features/employees/widgets/sheets/edit_person_sheet.dart';
import 'package:scheduling/features/employees/widgets/sheets/invite_person_sheet.dart';
import 'package:scheduling/features/employees/widgets/views/employee_details_view.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../support/tour_test_support.dart';

class _MockRepo extends Mock implements EmployeesRepository {}

const _employee = EmployeeRecord(
  id: 'e1',
  name: 'Theo Roy',
  firstName: 'Theo',
  lastName: 'Roy',
  email: 'theo@example.com',
  phone: '514-555-0100',
  role: 'admin',
  status: 'active',
  jobTitle: JobTitle.leadTech,
  maxJobsPerDay: 4,
  onCall: true,
);

const _invited = EmployeeRecord(
  id: 'inv1',
  name: 'Zoé Roy',
  firstName: 'Zoé',
  lastName: 'Roy',
  email: 'zoe@example.com',
  phone: '(514) 555-1234',
  status: 'invited',
  jobTitle: JobTitle.technician,
);

/// 375x667 is the reference phone; the sweep runs the redesigned Team surfaces
/// across the text scales the app itself offers (the in-app XL setting is
/// exactly 1.4) plus the OS extreme.
const _scales = [0.8, 1.0, 1.4, 2.0];

Widget _wrap(Widget child, double scale, {EmployeesRepository? repo}) =>
    ProviderScope(
      overrides: [
        employeesRepositoryProvider.overrideWithValue(repo ?? _MockRepo()),
        isOfflineProvider.overrideWithValue(false),
        authUidProvider.overrideWith(
          (ref) => Stream<String?>.value('admin-uid'),
        ),
        employeeJobsTodayProvider.overrideWithValue(const {'e1': 3}),
        employeeTodayJobsProvider('e1').overrideWithValue(const []),
        futureAssignmentCountProvider('e1').overrideWith((_) async => 2),
      ],
      child: ThemeNotifier(
        themeMode: ThemeMode.light,
        toggleTheme: () {},
        textScale: scale,
        setTextScale: (_) {},
        setLanguage: (_) {},
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          builder: (context, inner) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: inner ?? const SizedBox.shrink(),
          ),
          home: Scaffold(body: child),
        ),
      ),
    );

void main() {
  setUp(markFormToursSeen);

  setUpAll(() {
    registerFallbackValue(const EmployeeRecord(id: 'fallback'));
  });

  Future<void> sweep(
    WidgetTester tester,
    Widget Function() build, {
    // The two form sheets are lazy scroll views; a short viewport simply does
    // not build their lower half, so they sweep tall enough to lay all of it
    // out at once. The roster row and the detail view fit the reference phone.
    bool tall = false,
    EmployeesRepository? repo,
    Future<void> Function(WidgetTester tester)? after,
  }) async {
    for (final scale in _scales) {
      tester.view.physicalSize = tall
          ? const Size(375, 2400)
          : const Size(375, 667);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(build(), scale, repo: repo));
      await tester.pumpAndSettle();
      if (after != null) await after(tester);

      expect(
        tester.takeException(),
        isNull,
        reason: 'overflowed at text scale $scale',
      );
    }
  }

  testWidgets('roster row survives every text scale', (tester) async {
    await sweep(
      tester,
      () => EmployeeCard(employee: _employee, onTap: () {}),
    );
  });

  testWidgets('detail view survives every text scale', (tester) async {
    await sweep(
      tester,
      () => EmployeeDetailsView(
        employee: _employee,
        isCurrentUserAdmin: true,
        onEdit: () {},
      ),
    );
  });

  testWidgets('edit sheet survives every text scale', (tester) async {
    await sweep(
      tester,
      () => const EditPersonSheet(employee: _employee),
      tall: true,
    );
  });

  testWidgets('invite sheet survives every text scale', (tester) async {
    await sweep(tester, () => const InvitePersonSheet(), tall: true);
  });

  // The densest new layout in the project: the revealed 19px mono code and its
  // Copy pill on one line, then two equal-width bordered actions. The roster
  // hosts the tile inside a scrollable, so this sweep does too — vertical
  // extent is the list's problem, horizontal overflow is the tile's.
  testWidgets('the expanded pending-account row survives every text scale', (
    tester,
  ) async {
    final repo = _MockRepo();
    when(
      () => repo.createEmployeeAccount(
        name: any(named: 'name'),
        firstName: any(named: 'firstName'),
        lastName: any(named: 'lastName'),
        email: any(named: 'email'),
        phone: any(named: 'phone'),
        colorValue: any(named: 'colorValue'),
        jobTitle: any(named: 'jobTitle'),
      ),
    ).thenAnswer(
      (_) async => const NewAccountCredentials(
        email: 'zoe@example.com',
        password: 'Welcome123!',
      ),
    );

    await sweep(
      tester,
      // A fresh key per scale: pumpWidget reuses the State otherwise, so the
      // second tap would collapse an already-expanded row instead of opening
      // it.
      () => SingleChildScrollView(
        child: PendingInviteTile(key: UniqueKey(), employee: _invited),
      ),
      repo: repo,
      after: (tester) async {
        await tester.tap(find.text('Zoé Roy'));
        // The credentials sit in SelectableTexts whose cursors never settle,
        // so pump a fixed span rather than settling.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        // Nothing was reset, so the row holds no credential to show: the
        // masked value and its hint are what must survive the sweep.
        expect(find.text(kMaskedCredential), findsOneWidget);
        expect(
          find.text('Reset password to issue a new one'),
          findsOneWidget,
        );
      },
    );
  });
}
