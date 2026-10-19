import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/images/appointment_image_loader.dart';
import 'package:scheduling/core/images/appointment_storage_image.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/image_viewer.dart';
import 'package:scheduling/features/calendar/widgets/views/appointment_image_carousel.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockStorage extends Mock implements FirebaseStorage {}

class _FakeLoader extends AppointmentImageLoader {
  _FakeLoader() : super(storage: _MockStorage(), logger: AppLogger());

  final completer = Completer<Uint8List>();
  int loads = 0;

  @override
  Future<Uint8List> load(AppointmentImage image) {
    loads++;
    return completer.future;
  }
}

const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
];

Widget _harness(List<ImageProvider> images) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: AppointmentImageCarousel(images: images)),
);

SemanticsData _slide(WidgetTester tester, int position) => tester
    .getSemantics(find.bySemanticsLabel('Photo $position of 3'))
    .getSemanticsData();

Future<void> _next(WidgetTester tester) async {
  await tester.drag(find.byType(PageView), const Offset(-700, 0));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('pins the semantics of local, refused and remote slides', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final loader = _FakeLoader();
    final remote = AppointmentStorageImage(
      const AppointmentImage(storagePath: 'appointments/j1/images/a'),
      loader,
    );
    await tester.pumpWidget(
      _harness([MemoryImage(Uint8List.fromList(_png)), refusedImage, remote]),
    );
    await tester.pump();

    var data = _slide(tester, 1);
    expect(data.label, 'Photo 1 of 3');
    expect(data.hint, 'Open full screen');
    expect(data.value, '');

    await _next(tester);
    data = _slide(tester, 2);
    expect(data.label, 'Photo 2 of 3');
    expect(data.value, 'Photo unavailable');
    expect(data.hint, '');

    await _next(tester);
    data = _slide(tester, 3);
    expect(data.label, 'Photo 3 of 3');
    expect(data.value, 'Loading photo');
    expect(data.hint, '');

    loader.completer.complete(Uint8List.fromList(_png));
    await tester.pump();
    await tester.pump();
    data = _slide(tester, 3);
    expect(data.value, '');
    expect(data.hint, 'Open full screen');
    handle.dispose();
  });

  testWidgets('a rebuild does not refetch a remote photo', (tester) async {
    final loader = _FakeLoader();
    final remote = AppointmentStorageImage(
      const AppointmentImage(storagePath: 'appointments/j1/images/a'),
      loader,
    );
    await tester.pumpWidget(_harness([remote]));
    await tester.pump();
    final before = loader.loads;
    await tester.pumpWidget(_harness([remote]));
    await tester.pump();
    expect(loader.loads, before);
  });
}
