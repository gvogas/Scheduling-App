import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_rules.dart';

void main() {
  group('scanRules', () {
    test('clean tree has no violations', () {
      expect(
        scanRules({'lib/features/a/widgets/x.dart': 'class X {}'}),
        isEmpty,
      );
    });

    test('firebase_analytics outside the service is flagged', () {
      final v = scanRules({
        'lib/features/a/b.dart':
            "import 'package:firebase_analytics/firebase_analytics.dart';",
        'lib/core/analytics/analytics_service.dart':
            "import 'package:firebase_analytics/firebase_analytics.dart';",
      });
      expect(v.map((e) => e.rule), ['analytics-import']);
      expect(v.single.path, 'lib/features/a/b.dart');
    });

    test('FirebaseFirestore.instance outside the allowlist is flagged', () {
      final v = scanRules({
        'lib/features/a/screens/s.dart':
            'final f = FirebaseFirestore.instance;',
        'lib/core/providers/firebase_providers.dart':
            '(ref) => FirebaseFirestore.instance,',
      });
      expect(v.map((e) => e.rule), ['firestore-instance']);
    });

    test('strict callable map cast is flagged', () {
      final v = scanRules({
        'lib/a.dart': 'final m = r.data as Map<String, dynamic>?;',
      });
      expect(v.map((e) => e.rule), ['strict-map-cast']);
    });

    test('Timer in a widget or screen is flagged, elsewhere is not', () {
      final v = scanRules({
        'lib/features/a/widgets/w.dart': 'final t = Timer(d, f);',
        'lib/features/a/screens/s.dart': 'final t = Timer.periodic(d, f);',
        'lib/features/a/application/c.dart': 'final t = Timer(d, f);',
      });
      expect(v.map((e) => e.rule), ['widget-timer', 'widget-timer']);
    });

    test('ref.read inside a catch block is flagged', () {
      final v = scanRules({
        'lib/a.dart': '''
void f() {
  final logger = ref.read(loggerProvider);
  try {
    g();
  } catch (e, st) {
    ref.read(loggerProvider).warn('X', e, st);
  }
}''',
      });
      expect(v.map((e) => e.rule), ['ref-read-in-catch']);
      expect(v.single.line, 6);
    });

    test('ref.read on the same line as the catch is flagged', () {
      final v = scanRules({
        'lib/a.dart':
            "void f() {\n  try { g(); } catch (e) { ref.read(loggerProvider).warn('X', e); }\n}",
      });
      expect(v.map((e) => e.rule), ['ref-read-in-catch']);
      expect(v.single.line, 2);
    });

    test(
      'ref.read in a catchError callback is flagged, its receiver is not',
      () {
        final v = scanRules({
          'lib/a.dart': '''
Future<void> f() async {
  await ref.read(readyProvider.future).catchError((Object e) {
    ref.read(loggerProvider).warn('X', e);
  });
}''',
        });
        expect(v.map((e) => e.rule), ['ref-read-in-catch']);
        expect(v.single.line, 3);
      },
    );

    test('generated files are skipped', () {
      expect(
        scanRules({
          'lib/l10n/.gen/app_localizations.dart': 'as Map<String, dynamic>?',
          'lib/a.freezed.dart': 'as Map<String, dynamic>?',
          'lib/a.g.dart': 'as Map<String, dynamic>?',
        }),
        isEmpty,
      );
    });
  });
}
