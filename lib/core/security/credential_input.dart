/// The value every field that receives a credential passes to
/// `enableIMEPersonalizedLearning` — `TextField`, `CupertinoTextField` and
/// anything wrapping them.
///
/// Set it **unconditionally**, beside `obscureText`, and never lean on
/// `obscureText` to imply it: every password field in this app carries a
/// Show/Hide toggle, so the instant it is tapped the field renders plain text
/// at the framework's `true` default, and a third-party keyboard is free to
/// retain and cloud-sync what was typed. `keyboardType: visiblePassword` does
/// not imply it either. That is exactly how `AuthPasswordField` and both
/// `PasswordReauthDialog` variants once shipped without it — the rule is
/// named here so a new credential field has a symbol to copy rather than a
/// paragraph to remember. See `.claude/rules/security.md`.
const bool kCredentialImePersonalizedLearning = false;
