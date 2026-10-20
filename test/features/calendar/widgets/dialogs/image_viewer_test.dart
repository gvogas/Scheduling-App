import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/image_viewer.dart';
import 'package:scheduling/l10n/l10n.dart';

/// 1x1 transparent PNG so the Image decodes for real in tests.
final Uint8List _kTransparentPng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
]);

/// Distinct providers so `PageView` really builds N pages — several identical
/// `MemoryImage`s over the same bytes compare equal.
List<ImageProvider> _pages(int count) => [
  for (var i = 0; i < count; i++)
    MemoryImage(_kTransparentPng, scale: 1 + (i / 100)),
];

Widget _host({
  bool disableAnimations = false,
  List<ImageProvider>? images,
  int initialIndex = 0,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => ImageViewer.open(
                context,
                images: images ?? [MemoryImage(_kTransparentPng)],
                initialIndex: initialIndex,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _open(
  WidgetTester tester, {
  bool disableAnimations = false,
  List<ImageProvider>? images,
  int initialIndex = 0,
}) async {
  await tester.pumpWidget(
    _host(
      disableAnimations: disableAnimations,
      images: images,
      initialIndex: initialIndex,
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(ImageViewer), findsOneWidget);
}

void main() {
  testWidgets('drag down past the threshold dismisses the viewer', (
    tester,
  ) async {
    await _open(tester);

    await tester.drag(find.byType(PageView), const Offset(0, 250));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewer), findsNothing);
  });

  testWidgets('a short drag snaps back instead of dismissing', (tester) async {
    await _open(tester);

    await tester.drag(find.byType(PageView), const Offset(0, 60));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewer), findsOneWidget);
  });

  testWidgets('drag-dismiss still works with reduce-motion on', (
    tester,
  ) async {
    await _open(tester, disableAnimations: true);

    await tester.drag(find.byType(PageView), const Offset(0, 250));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewer), findsNothing);
  });

  testWidgets('tap dismisses the viewer', (tester) async {
    await _open(tester);

    await tester.tap(find.byType(PageView), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewer), findsNothing);
  });

  test('the refused-photo stand-in is a real image, never empty bytes', () {
    // An empty MemoryImage throws out of the decoder; a blank slot is wanted.
    expect(refusedImage.bytes, isNotEmpty);
    expect(isRefusedImage(refusedImage), isTrue);
  });

  group('ImageViewer.open clamps its initial index', () {
    testWidgets('an index past the end lands on the last photo', (
      tester,
    ) async {
      // Composed by the caller from two lists (resolved urls + local files),
      // the first of which can still be resolving — so it really can point
      // past the end. Unclamped, Save/Share reads images[_currentIndex] and
      // throws a RangeError out of a gesture handler.
      await _open(tester, images: _pages(3), initialIndex: 7);

      expect(
        tester.widget<ImageViewer>(find.byType(ImageViewer)).initialIndex,
        2,
      );
      expect(find.text('3 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a negative index lands on the first photo', (tester) async {
      await _open(tester, images: _pages(3), initialIndex: -4);

      expect(
        tester.widget<ImageViewer>(find.byType(ImageViewer)).initialIndex,
        0,
      );
      expect(find.text('1 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty image list does not throw', (tester) async {
      // `images.length - 1` is -1 here, so the clamp has to short-circuit
      // before it rather than pass an invalid range.
      await _open(tester, images: const [], initialIndex: 5);

      expect(
        tester.widget<ImageViewer>(find.byType(ImageViewer)).initialIndex,
        0,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
