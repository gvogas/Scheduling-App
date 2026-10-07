import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/cards/selected_client_card.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  const marie = ClientRecord(
    id: 'c1',
    name: 'Marie Tremblay',
    phone: '5145628332',
    address: '4820 rue Wellington',
    city: 'Verdun',
    jobCount: 12,
  );

  Widget harness({
    required ClientRecord client,
    bool useClientAddress = true,
    VoidCallback? onChange,
    VoidCallback? onRemove,
    ValueChanged<bool>? onUseClientAddressChanged,
    double textScale = 1,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: SelectedClientCard(
          client: client,
          useClientAddress: useClientAddress,
          lastVisitLabel: '14 Aug',
          onChange: onChange ?? () {},
          onRemove: onRemove ?? () {},
          onUseClientAddressChanged: onUseClientAddressChanged ?? (_) {},
        ),
      ),
    ),
  );

  testWidgets('the number is the headline and the name is the qualifier',
      (tester) async {
    await tester.pumpWidget(harness(client: marie));
    expect(find.text('(514) 562-8332'), findsOneWidget);
    expect(find.textContaining('Marie Tremblay'), findsOneWidget);
    expect(find.textContaining('12 jobs'), findsOneWidget);
  });

  testWidgets('the address switch reports both directions', (tester) async {
    final changes = <bool>[];
    await tester.pumpWidget(harness(
      client: marie,
      onUseClientAddressChanged: changes.add,
    ));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(changes, [false]);
  });

  testWidgets('the declined address stays visible when the switch is off',
      (tester) async {
    await tester.pumpWidget(harness(client: marie, useClientAddress: false));
    expect(find.textContaining('4820 rue Wellington'), findsOneWidget);
  });

  testWidgets('Change and Remove both fire', (tester) async {
    var changed = false;
    var removed = false;
    await tester.pumpWidget(harness(
      client: marie,
      onChange: () => changed = true,
      onRemove: () => removed = true,
    ));
    await tester.tap(find.text('Change'));
    await tester.tap(find.text('Remove'));
    expect(changed, isTrue);
    expect(removed, isTrue);
  });

  testWidgets('a client with no job count omits the count rather than showing 0',
      (tester) async {
    await tester.pumpWidget(harness(
      client: marie.copyWith(jobCount: null),
    ));
    expect(find.textContaining('0 jobs'), findsNothing);
  });

  testWidgets('no overflow at 260px and 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(harness(client: marie, textScale: 2));
    expect(tester.takeException(), isNull);
  });
}
