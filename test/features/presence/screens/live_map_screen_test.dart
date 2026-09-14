import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/maps/application/maps_providers.dart';
import 'package:scheduling/features/maps/domain/places_repository.dart';
import 'package:scheduling/features/presence/application/live_map_providers.dart';
import 'package:scheduling/features/presence/domain/models/presence_fix.dart';
import 'package:scheduling/features/presence/screens/live_map_screen.dart';
import 'package:scheduling/l10n/l10n.dart';

final _now = DateTime(2026, 7, 17, 12);

const _alice = EmployeeRecord(
  id: 'u1',
  name: 'Alice',
  status: 'active',
  locationSharingEnabled: true,
);
const _bob = EmployeeRecord(
  id: 'u2',
  name: 'Bob',
  status: 'active',
  locationSharingEnabled: true,
);

class _MockPlaces extends Mock implements PlacesRepository {}

PresenceFix _fix(String id, double lat, double lng, DateTime updatedAt) =>
    PresenceFix(userDocId: id, lat: lat, lng: lng, updatedAt: updatedAt);

void main() {
  late LiveMapConfig? lastConfig;
  late _MockPlaces places;

  setUp(() {
    lastConfig = null;
    // Every on-map row resolves its city, so an unstubbed repository would
    // reach for a Firebase app that does not exist here.
    places = _MockPlaces();
    when(
      () => places.reverseGeocode(
        lat: any(named: 'lat'),
        lng: any(named: 'lng'),
        locale: any(named: 'locale'),
      ),
    ).thenAnswer((_) async => null);
  });

  Widget stubMap(LiveMapConfig config) {
    lastConfig = config;
    return const ColoredBox(color: Color(0xFF888888));
  }

  Widget themed(Widget child, {double textScale = 1}) => ThemeNotifier(
    themeMode: ThemeMode.light,
    toggleTheme: () {},
    textScale: textScale,
    setTextScale: (_) {},
    setLanguage: (_) {},
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: app!,
      ),
      home: child,
    ),
  );

  Widget wrap({
    required List<Override> overrides,
    Widget child = const LiveMapScreen(isAdmin: true, employeeId: 'e1'),
    double textScale = 1,
  }) => ProviderScope(
    overrides: overrides,
    child: themed(child, textScale: textScale),
  );

  /// Tall enough that the whole team sheet is built at its resting height.
  void useTallViewport(
    WidgetTester tester, {
    Size size = const Size(800, 2000),
  }) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  // Marker icons encode via real dart:ui async that the fake test clock won't advance — drive under runAsync.
  Future<void> settleMap(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    });
    await tester.pump();
  }

  List<Override> baseOverrides({
    required Stream<List<PresenceFix>> presence,
    List<EmployeeRecord> users = const [_alice, _bob],
    StreamController<int>? tick,
    List<Override> extra = const [],
  }) => [
    allPresenceStreamProvider.overrideWith((ref) => presence),
    allUsersStreamProvider.overrideWith((ref) => Stream.value(users)),
    liveMapClockProvider.overrideWith(
      (ref) =>
          () => _now,
    ),
    liveMapTickProvider.overrideWith(
      (ref) => tick?.stream ?? const Stream<int>.empty(),
    ),
    placesRepositoryProvider.overrideWithValue(places),
    ...extra,
  ];

  testWidgets('builds a marker per active staff member (incl. a stale one)', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        overrides: baseOverrides(
          presence: Stream.value([
            _fix('u1', 45.5, -73.6, _now),
            _fix('u2', 45.6, -73.7, _now.subtract(const Duration(minutes: 40))),
          ]),
        ),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await settleMap(tester);

    expect(lastConfig, isNotNull);
    expect(lastConfig!.markers, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a marker focuses that person at the top of the sheet '
      'with name, freshness, and the resolved address', (tester) async {
    final key = ReverseGeocodeQuery(lat: 45.5, lng: -73.6, locale: 'en');
    await tester.pumpWidget(
      wrap(
        overrides: baseOverrides(
          presence: Stream.value([_fix('u1', 45.5, -73.6, _now)]),
          users: const [_alice],
          extra: [
            reverseGeocodeProvider(
              key,
            ).overrideWith((ref) async => '123 Alice St'),
          ],
        ),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await settleMap(tester);

    final marker = lastConfig!.markers.firstWhere(
      (m) => m.markerId.value == 'u1',
    );
    marker.onTap!();
    await settleMap(tester);

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Just now'), findsOneWidget);
    expect(find.text('123 Alice St'), findsOneWidget);
  });

  testWidgets('the address line is hidden when no address is available '
      '(same branch as a lookup failure)', (tester) async {
    final key = ReverseGeocodeQuery(lat: 45.5, lng: -73.6, locale: 'en');
    await tester.pumpWidget(
      wrap(
        overrides: baseOverrides(
          presence: Stream.value([_fix('u1', 45.5, -73.6, _now)]),
          users: const [_alice],
          // A null result (no address / lookup failure) takes the same
          // `SizedBox.shrink()` branch in the info card.
          extra: [
            reverseGeocodeProvider(key).overrideWith((ref) async => null),
          ],
        ),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await settleMap(tester);

    lastConfig!.markers.first.onTap!();
    await settleMap(tester);

    // Card still shows the person, but no address / resolving line.
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Finding address…'), findsNothing);
    expect(find.text('123 Alice St'), findsNothing);
  });

  testWidgets('empty presence data renders the empty-state card over the map', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        overrides: baseOverrides(
          presence: Stream.value(const []),
          users: const [_alice],
        ),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(lastConfig, isNotNull, reason: 'map still renders when empty');
    expect(
      find.text('No one is sharing their location right now'),
      findsOneWidget,
    );
  });

  testWidgets('the team sheet survives the empty-state card going away', (
    tester,
  ) async {
    final presence = StreamController<List<PresenceFix>>.broadcast();
    addTearDown(presence.close);
    await tester.pumpWidget(
      wrap(
        overrides: baseOverrides(presence: presence.stream),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await tester.pump();
    presence.add(const []);
    await settleMap(tester);
    expect(
      find.text('No one is sharing their location right now'),
      findsOneWidget,
    );

    presence.add([_fix('u1', 45.5, -73.6, _now)]);
    await settleMap(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets('a presence stream error renders the error body', (tester) async {
    await tester.pumpWidget(
      wrap(
        overrides: baseOverrides(
          presence: Stream<List<PresenceFix>>.error(Exception('denied')),
          users: const [_alice],
        ),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load the staff map"), findsOneWidget);
    expect(lastConfig, isNull, reason: 'no map is built in the error state');
  });

  testWidgets(
    'pauses the presence stream while the tab is hidden and re-attaches when '
    'it becomes visible',
    (tester) async {
      final presence = StreamController<List<PresenceFix>>.broadcast();
      addTearDown(presence.close);

      late StateSetter setOuter;
      // The hub wraps each tab in TickerMode(enabled: tab == current); mirror
      // that so a hidden tab (enabled: false) detaches its data watches.
      var visible = false;

      await tester.pumpWidget(
        wrap(
          overrides: baseOverrides(presence: presence.stream),
          child: StatefulBuilder(
            builder: (context, setState) {
              setOuter = setState;
              return TickerMode(
                enabled: visible,
                child: LiveMapScreen(
                  isAdmin: true,
                  employeeId: 'e1',
                  mapBuilder: stubMap,
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();

      expect(
        presence.hasListener,
        isFalse,
        reason: 'hidden tab must not watch the presence stream',
      );

      setOuter(() => visible = true);
      await tester.pump();
      await tester.pump();

      expect(
        presence.hasListener,
        isTrue,
        reason: 'becoming visible re-attaches the presence stream',
      );
    },
  );

  testWidgets('the team sheet counts who is on the map, not seen, and not '
      'sharing', (tester) async {
    useTallViewport(tester);
    const carol = EmployeeRecord(id: 'u3', name: 'Carol', status: 'active');
    const dave = EmployeeRecord(
      id: 'u4',
      name: 'Dave',
      status: 'active',
      locationSharingEnabled: true,
    );
    await tester.pumpWidget(
      wrap(
        overrides: baseOverrides(
          presence: Stream.value([
            _fix('u1', 45.5, -73.6, _now),
            _fix('u2', 45.6, -73.7, _now.subtract(const Duration(hours: 3))),
          ]),
          users: const [_alice, _bob, carol, dave],
        ),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await settleMap(tester);

    expect(
      [
        find.text('ON THE MAP · 2'),
        find.text('NOT SEEN YET · 1'),
        find.text('LOCATION SHARING OFF · 1'),
      ].map((f) => f.evaluate().length),
      [1, 1, 1],
    );
  });

  testWidgets('a pin older than two hours keeps its marker', (tester) async {
    await tester.pumpWidget(
      wrap(
        overrides: baseOverrides(
          presence: Stream.value([
            _fix('u1', 45.5, -73.6, _now),
            _fix('u2', 45.6, -73.7, _now.subtract(const Duration(hours: 3))),
          ]),
        ),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await settleMap(tester);

    expect(
      lastConfig!.markers.map((m) => m.markerId.value),
      unorderedEquals(['u1', 'u2']),
    );
  });

  testWidgets('a test account is neither a marker nor a row', (tester) async {
    useTallViewport(tester);
    const apple = EmployeeRecord(
      id: 'u4',
      name: 'Apple Tester',
      status: 'active',
      locationSharingEnabled: true,
      isTestAccount: true,
    );
    await tester.pumpWidget(
      wrap(
        overrides: baseOverrides(
          presence: Stream.value([_fix('u4', 45.5, -73.6, _now)]),
          users: const [_alice, apple],
        ),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await settleMap(tester);

    expect(find.text('Apple Tester'), findsNothing);
    expect(lastConfig!.markers, isEmpty);
  });

  testWidgets('tapping a row focuses that person', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        overrides: baseOverrides(
          presence: Stream.value([
            _fix('u1', 45.5, -73.6, _now),
            _fix('u2', 45.6, -73.7, _now),
          ]),
        ),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await settleMap(tester);
    expect(find.text('Open in Maps'), findsNothing);

    await tester.tap(find.text('Bob'));
    await settleMap(tester);

    expect(find.text('Open in Maps'), findsOneWidget);
  });

  testWidgets('survives 260x640 at 2.0 text scale with someone focused', (
    tester,
  ) async {
    useTallViewport(tester, size: const Size(260, 640));
    const carol = EmployeeRecord(
      id: 'u3',
      name: 'Carol Beaulieu-Tremblay',
      status: 'active',
    );
    await tester.pumpWidget(
      wrap(
        textScale: 2,
        overrides: baseOverrides(
          presence: Stream.value([
            _fix('u1', 45.5, -73.6, _now),
            _fix('u2', 45.6, -73.7, _now.subtract(const Duration(hours: 3))),
          ]),
          users: const [_alice, _bob, carol],
        ),
        child: LiveMapScreen(
          isAdmin: true,
          employeeId: 'e1',
          mapBuilder: stubMap,
        ),
      ),
    );
    await settleMap(tester);
    lastConfig!.markers.first.onTap!();
    await settleMap(tester);

    expect(tester.takeException(), isNull);
  });
}
