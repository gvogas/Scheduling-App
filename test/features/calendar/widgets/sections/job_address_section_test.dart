import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/widgets/sections/job_address_section.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  const marie = ClientRecord(
    id: 'c1',
    name: 'Marie Tremblay',
    firstName: 'Marie',
    phone: '5145628332',
    address: '4820 rue Wellington',
    city: 'Verdun',
  );

  Widget harness({
    required bool useCustomAddress,
    List<String> previousAddresses = const [],
    ValueChanged<String>? onPickPrevious,
    double textScale = 1,
  }) => ProviderScope(
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: JobAddressSection(
            selectedClient: marie,
            useCustomAddress: useCustomAddress,
            addressController: TextEditingController(),
            previousAddresses: previousAddresses,
            onPickPrevious: onPickPrevious ?? (_) {},
            onSwitchToCustom: () {},
            onUseClientAddress: () {},
          ),
        ),
      ),
    ),
  );

  testWidgets('with the client address in use, no previous list is offered', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        useCustomAddress: false,
        previousAddresses: const ['1250 boul. LaSalle'],
      ),
    );
    expect(find.textContaining('has been here before'), findsNothing);
  });

  testWidgets('switching off offers the client previous job addresses first', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        useCustomAddress: true,
        previousAddresses: const ['1250 boul. LaSalle', "88 rue de l'Église"],
      ),
    );
    expect(find.text('Marie has been here before'), findsOneWidget);
    expect(find.text('1250 boul. LaSalle'), findsOneWidget);
    expect(find.text('Search for another address…'), findsOneWidget);
  });

  testWidgets('tapping a previous address reports it', (tester) async {
    String? picked;
    await tester.pumpWidget(
      harness(
        useCustomAddress: true,
        previousAddresses: const ['1250 boul. LaSalle'],
        onPickPrevious: (a) => picked = a,
      ),
    );
    await tester.tap(find.text('1250 boul. LaSalle'));
    expect(picked, '1250 boul. LaSalle');
  });

  testWidgets('after a pick the list gives way to the address field', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        useCustomAddress: true,
        previousAddresses: const ['1250 boul. LaSalle', '1260 boul. LaSalle'],
      ),
    );
    expect(find.text('Search for another address…'), findsOneWidget);
    await tester.tap(find.text('1250 boul. LaSalle'));
    await tester.pumpAndSettle();
    expect(find.text('Search for another address…'), findsNothing);
    expect(find.text('1260 boul. LaSalle'), findsNothing);
  });

  testWidgets('with no history the autocomplete is the whole section', (
    tester,
  ) async {
    await tester.pumpWidget(harness(useCustomAddress: true));
    expect(find.textContaining('has been here before'), findsNothing);
    expect(find.text('Search for another address…'), findsNothing);
  });

  testWidgets('no overflow at 260px and 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      harness(
        useCustomAddress: true,
        previousAddresses: const ['1250 boul. LaSalle', "88 rue de l'Église"],
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('units on one street render under a shared street header', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        useCustomAddress: true,
        previousAddresses: const [
          '1751 rue Richardson unit 404',
          '1751 rue Richardson unit 210',
        ],
      ),
    );
    expect(find.text('Units billed to this client'), findsOneWidget);
    expect(find.text('404'), findsOneWidget);
    expect(find.textContaining('has been here before'), findsNothing);
  });

  testWidgets('picking a unit row reports the full address', (tester) async {
    String? picked;
    await tester.pumpWidget(
      harness(
        useCustomAddress: true,
        previousAddresses: const [
          '1751 rue Richardson unit 404',
          '1751 rue Richardson unit 210',
        ],
        onPickPrevious: (a) => picked = a,
      ),
    );
    await tester.tap(find.text('404'));
    expect(picked, '1751 rue Richardson unit 404');
  });
}
