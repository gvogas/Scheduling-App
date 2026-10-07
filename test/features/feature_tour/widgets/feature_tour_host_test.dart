import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/features/feature_tour/application/tour_seen_store.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/feature_tour/widgets/feature_tour_host.dart';
import 'package:scheduling/features/feature_tour/widgets/tour_showcase.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeShell implements HubTabSelector {
  @override
  void select(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName = '',
    String userEmail = '',
  }) {}

  @override
  void selectAndReveal(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName = '',
    String userEmail = '',
  }) {}

  @override
  void goHome() {}
}

void main() {
  Widget harness({
    required HubTab current,
    required TourScope scope,
    required Map<TourStepId, GlobalKey> stepKeys,
    required Widget child,
    required ProviderContainer container,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: HubShellScope(
          shell: _FakeShell(),
          current: current,
          child: FeatureTourHost(
            scope: scope,
            isAdmin: true,
            stepKeys: stepKeys,
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
  }

  ProviderContainer newContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.listen(tourSeenProvider, (_, _) {});
    return c;
  }

  testWidgets('does not start while its tab is hidden', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = newContainer();
    final key = GlobalKey();
    await tester.pumpWidget(
      harness(
        current: HubTab.calendar, // another tab is visible
        scope: const DestinationTour(HubTab.clients),
        stepKeys: {TourStepId.clientsSearch: key},
        container: container,
        child: TourShowcase(
          showcaseKey: key,
          scope: const DestinationTour(HubTab.clients),
          id: TourStepId.clientsSearch,
          index: 0,
          count: 2,
          child: const Text('target'),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(find.text('Find a client'), findsNothing);
    expect(
      container.read(tourSeenProvider),
      isNot(contains(TourStepId.clientsSearch)),
    );
  });

  testWidgets('marks nothing seen when no target is mounted', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = newContainer();
    await tester.pumpWidget(
      harness(
        current: HubTab.clients,
        scope: const DestinationTour(HubTab.clients),
        stepKeys: {TourStepId.clientsSearch: GlobalKey()}, // never attached
        container: container,
        child: const Text('no showcase targets here'),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    // Nothing rendered, so nothing was seen — the next visit retries.
    expect(container.read(tourSeenProvider), isEmpty);
  });

  testWidgets('starts and shows the first step when visible and unseen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final container = newContainer();
    final searchKey = GlobalKey();
    final addKey = GlobalKey();
    await tester.pumpWidget(
      harness(
        current: HubTab.clients,
        scope: const DestinationTour(HubTab.clients),
        stepKeys: {
          TourStepId.clientsSearch: searchKey,
          TourStepId.clientsAdd: addKey,
        },
        container: container,
        child: Column(
          children: [
            TourShowcase(
              showcaseKey: searchKey,
              scope: const DestinationTour(HubTab.clients),
              id: TourStepId.clientsSearch,
              index: 0,
              count: 2,
              child: const Text('search target'),
            ),
            TourShowcase(
              showcaseKey: addKey,
              scope: const DestinationTour(HubTab.clients),
              id: TourStepId.clientsAdd,
              index: 1,
              count: 2,
              child: const Text('add target'),
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(find.text('Find a client'), findsOneWidget);
    expect(find.text('1 of 2'), findsOneWidget);
  });

  testWidgets('does not start when every step is already seen', (tester) async {
    SharedPreferences.setMockInitialValues({
      'tour_seen_steps': [
        TourStepId.clientsSearch.name,
        TourStepId.clientsFilter.name,
        TourStepId.clientsAdd.name,
        TourStepId.clientsRow.name,
      ],
    });
    final container = newContainer();
    final key = GlobalKey();
    await tester.pumpWidget(
      harness(
        current: HubTab.clients,
        scope: const DestinationTour(HubTab.clients),
        stepKeys: {TourStepId.clientsSearch: key},
        container: container,
        child: TourShowcase(
          showcaseKey: key,
          scope: const DestinationTour(HubTab.clients),
          id: TourStepId.clientsSearch,
          index: 0,
          count: 2,
          child: const Text('target'),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(find.text('Find a client'), findsNothing);
  });

  testWidgets('starts only the steps this device has not seen', (tester) async {
    SharedPreferences.setMockInitialValues({
      'tour_seen_steps': [TourStepId.clientsSearch.name],
    });
    final container = newContainer();
    final searchKey = GlobalKey();
    final addKey = GlobalKey();
    await tester.pumpWidget(
      harness(
        current: HubTab.clients,
        scope: const DestinationTour(HubTab.clients),
        stepKeys: {
          TourStepId.clientsSearch: searchKey,
          TourStepId.clientsAdd: addKey,
        },
        container: container,
        child: Column(
          children: [
            TourShowcase(
              showcaseKey: searchKey,
              scope: const DestinationTour(HubTab.clients),
              id: TourStepId.clientsSearch,
              index: 0,
              count: 2,
              child: const Text('search target'),
            ),
            TourShowcase(
              showcaseKey: addKey,
              scope: const DestinationTour(HubTab.clients),
              id: TourStepId.clientsAdd,
              index: 1,
              count: 2,
              child: const Text('add target'),
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    // The seen step is skipped, so the tour opens on the next one.
    expect(find.text('Find a client'), findsNothing);
    expect(find.text('Add a client'), findsOneWidget);
  });

  testWidgets('marks only the steps that actually ran', (tester) async {
    SharedPreferences.setMockInitialValues({'tour_seen_steps': <String>[]});
    final container = newContainer();
    final searchKey = GlobalKey();
    // Registered as a step, but never mounted — isTargetRendered drops it.
    final addKey = GlobalKey();
    await tester.pumpWidget(
      harness(
        current: HubTab.clients,
        scope: const DestinationTour(HubTab.clients),
        stepKeys: {
          TourStepId.clientsSearch: searchKey,
          TourStepId.clientsAdd: addKey,
        },
        container: container,
        child: TourShowcase(
          showcaseKey: searchKey,
          scope: const DestinationTour(HubTab.clients),
          id: TourStepId.clientsSearch,
          index: 0,
          count: 1,
          child: const Text('search target'),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Skip'));
    await tester.pump(const Duration(seconds: 1));
    final seen = container.read(tourSeenProvider);
    expect(seen, {TourStepId.clientsSearch});
    // The dropped step stays unseen, so a later visit offers it again.
    expect(seen, isNot(contains(TourStepId.clientsAdd)));
  });

  testWidgets(
    'a pushed destination gates on its own route being current, not on the '
    'hub scope',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = newContainer();
      final navigatorKey = GlobalKey<NavigatorState>();
      final appearanceKey = GlobalKey();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: Text('root')),
          ),
        ),
      );

      // Both pushes in one batch, so the toured route is never momentarily
      // on top — otherwise it gets a legitimate window to start.
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => FeatureTourHost(
            scope: const DestinationTour(PushedDestination.settings),
            isAdmin: true,
            stepKeys: {TourStepId.settingsAppearance: appearanceKey},
            child: Scaffold(
              body: TourShowcase(
                showcaseKey: appearanceKey,
                scope: const DestinationTour(PushedDestination.settings),
                id: TourStepId.settingsAppearance,
                index: 0,
                count: 1,
                child: const Text('settings-body'),
              ),
            ),
          ),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('on-top')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('on-top'), findsOneWidget);
      expect(
        find.text('Make it yours'),
        findsNothing,
        reason: 'a buried route must not start its tour',
      );
      expect(container.read(tourSeenProvider), isEmpty);

      // Popping back makes the route current again, re-opening the gate.
      // Bounded pumps, not pumpAndSettle: once a tour actually runs,
      // showcaseview's tooltip animation repeats and never settles.
      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
      expect(find.text('Make it yours'), findsOneWidget);
    },
  );

  testWidgets('a form sheet gates on its own modal route being current', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final container = newContainer();
    final navigatorKey = GlobalKey<NavigatorState>();
    const scope = FormTour(TourForm.addAppointment);
    final templatesKey = GlobalKey();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: Text('root')),
        ),
      ),
    );

    expect(
      container.read(tourSeenProvider),
      isEmpty,
      reason: 'nothing has opened the sheet yet',
    );

    // A ModalBottomSheetRoute is a ModalRoute, so the host's route branch
    // covers it with no third visibility mode.
    unawaited(
      showModalBottomSheet<void>(
        context: navigatorKey.currentContext!,
        builder: (_) => FeatureTourHost(
          scope: scope,
          isAdmin: true,
          stepKeys: {TourStepId.apptTemplates: templatesKey},
          child: TourShowcase(
            showcaseKey: templatesKey,
            scope: scope,
            id: TourStepId.apptTemplates,
            index: 0,
            count: 1,
            child: const Text('sheet-body'),
          ),
        ),
      ),
    );
    // Bounded pumps, not pumpAndSettle: the tour runs here, and
    // showcaseview's tooltip animation repeats and never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(find.text('sheet-body'), findsOneWidget);
    expect(
      find.text('Start from a job type'),
      findsOneWidget,
      reason: 'the sheet route is current, so its tour ran',
    );
  });
  testWidgets('a hub tab tour waits while a page covers the hub, then starts '
      'once it closes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = newContainer();
    final key = GlobalKey();
    const scope = DestinationTour(HubTab.clients);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          initialRoute: '/cover',
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (context) => settings.name == '/cover'
                ? Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('close'),
                    ),
                  )
                : HubShellScope(
                    shell: _FakeShell(),
                    current: HubTab.clients,
                    child: FeatureTourHost(
                      scope: scope,
                      isAdmin: true,
                      stepKeys: {TourStepId.clientsSearch: key},
                      child: Scaffold(
                        body: TourShowcase(
                          showcaseKey: key,
                          scope: scope,
                          id: TourStepId.clientsSearch,
                          index: 0,
                          count: 1,
                          child: const Text('target'),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Find a client'), findsNothing);

    await tester.tap(find.text('close'));
    // Bounded pumps: once the tour runs, its tooltip animation never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(find.text('Find a client'), findsOneWidget);
  });
}
