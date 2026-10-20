import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_hold.dart';
import 'package:scheduling/core/theme/design_tokens.dart';

/// U1: the hold is decided by kind, length, action and accessibility in one
/// pure function, so no call site can re-spell a duration.
void main() {
  const undo = NoticeAction(label: 'Undo', onPressed: _noop);

  test('success and info keep the design cycle', () {
    expect(
      noticeHoldFor(const AppNotice.success('Saved'), accessible: false),
      AppMotion.noticeCycle,
    );
    expect(
      noticeHoldFor(const AppNotice.info('Photos queued'), accessible: false),
      AppMotion.noticeCycle,
    );
  });

  test('an error holds at least 5 s plus 40 ms per character', () {
    expect(
      noticeHoldFor(const AppNotice.error(''), accessible: false),
      const Duration(seconds: 5),
    );
    expect(
      noticeHoldFor(AppNotice.error('x' * 20), accessible: false),
      const Duration(milliseconds: 5800),
    );
  });

  test('an error hold caps at 10 s however long the message', () {
    expect(
      noticeHoldFor(AppNotice.error('x' * 170), accessible: false),
      const Duration(seconds: 10),
    );
    expect(
      noticeHoldFor(AppNotice.error('x' * 125), accessible: false),
      const Duration(seconds: 10),
    );
  });

  test('a notice carrying an action holds at least 6 s', () {
    expect(
      noticeHoldFor(
        const AppNotice.success('Marked as complete', action: undo),
        accessible: false,
      ),
      const Duration(seconds: 6),
    );
  });

  test('accessible navigation floors every kind at 6 s', () {
    expect(
      noticeHoldFor(const AppNotice.success('Saved'), accessible: true),
      const Duration(seconds: 6),
    );
    expect(
      noticeHoldFor(const AppNotice.info('fyi'), accessible: true),
      const Duration(seconds: 6),
    );
    expect(
      noticeHoldFor(const AppNotice.error('short'), accessible: true),
      const Duration(seconds: 6),
    );
  });

  test('accessible navigation takes the max, never shortens a long error', () {
    expect(
      noticeHoldFor(AppNotice.error('x' * 100), accessible: true),
      const Duration(seconds: 9),
    );
  });
}

void _noop() {}
