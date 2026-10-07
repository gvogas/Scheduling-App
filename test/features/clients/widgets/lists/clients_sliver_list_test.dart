import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/domain/client_grouping.dart';
import 'package:scheduling/features/clients/widgets/lists/clients_sliver_list.dart';

Widget _harness(List<ClientGroup> groups) => MaterialApp(
  theme: lightTheme(),
  home: Scaffold(
    body: ClientsSliverList(
      groups: groups,
      itemBuilder: (context, index) => Material(
        color: Colors.blue,
        child: SizedBox(height: 56, child: Text('row $index')),
      ),
    ),
  ),
);

/// The clips the list puts around its own rows.
List<ClipRRect> _rowClips(WidgetTester tester) => tester
    .widgetList<ClipRRect>(
      find.descendant(
        of: find.byType(ClientsSliverList),
        matching: find.byType(ClipRRect),
      ),
    )
    .toList();

const _corner = Radius.circular(AppRadius.r12);

void main() {
  // DecoratedSliver paints the card behind its rows without clipping them, and
  // a row is a square Material + InkWell — so its ink, and a selected row's
  // fill, paint over the card's rounded corner against the page colour.
  testWidgets('clips the first and last row of a group to the card corners', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const [(heading: 'A', start: 0, length: 3)]),
    );
    await tester.pumpAndSettle();

    expect(find.text('row 2'), findsOneWidget);
    final clips = _rowClips(tester);
    expect(clips, hasLength(2));
    expect(
      clips.first.borderRadius,
      const BorderRadius.vertical(top: _corner),
      reason: 'the top row rounds only where the card does',
    );
    expect(
      clips.last.borderRadius,
      const BorderRadius.vertical(bottom: _corner),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('clips a lone row on all four corners', (tester) async {
    await tester.pumpWidget(
      _harness(const [(heading: 'A', start: 0, length: 1)]),
    );
    await tester.pumpAndSettle();

    final clips = _rowClips(tester);
    expect(clips, hasLength(1));
    expect(
      clips.single.borderRadius,
      const BorderRadius.vertical(top: _corner, bottom: _corner),
    );
  });

  // The whole reason this is a DecoratedSliver around a SliverList: one group
  // can hold every loaded row, and a Column would build them all eagerly.
  testWidgets('builds only the rows in view', (tester) async {
    await tester.pumpWidget(
      _harness(const [(heading: 'A', start: 0, length: 200)]),
    );
    await tester.pumpAndSettle();

    expect(find.text('row 0'), findsOneWidget);
    expect(find.text('row 199'), findsNothing);
  });
}
