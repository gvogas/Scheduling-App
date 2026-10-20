import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/theme/design_tokens.dart';

/// How long a notice stays on screen before it dismisses itself.
Duration noticeHoldFor(AppNotice notice, {required bool accessible}) {
  var hold = switch (notice) {
    NoticeError() => _errorHold(notice.message.length),
    NoticeSuccess() || NoticeInfo() => AppMotion.noticeCycle,
  };
  if (notice.action != null) hold = _atLeast(hold, AppMotion.noticeActionFloor);
  if (accessible) hold = _atLeast(hold, AppMotion.noticeAccessibleFloor);
  return hold;
}

Duration _errorHold(int characters) {
  final read =
      AppMotion.noticeErrorFloor + AppMotion.noticeErrorPerChar * characters;
  return read > AppMotion.noticeErrorCap ? AppMotion.noticeErrorCap : read;
}

Duration _atLeast(Duration hold, Duration floor) => hold < floor ? floor : hold;
