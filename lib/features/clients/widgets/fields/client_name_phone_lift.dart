import 'package:flutter/widgets.dart';

import 'package:scheduling/features/clients/domain/policies/client_name_policy.dart';

/// Moves a phone number typed or pasted into the NAME field over into the
/// phone field, formatted, and takes it back out of the name.
///
/// Wired to the name field's `onChanged` in BOTH client sheets (one instance
/// per State). [ClientNamePolicy.liftPhoneFromName] fires only into an empty
/// phone field — or one still holding what this lift last wrote, so a number
/// typed digit by digit keeps following the name instead of freezing at its
/// seventh digit. Once the admin edits the phone, it is theirs.
class NamePhoneLift {
  String? _lifted;

  /// Returns whether anything moved, so a caller can `setState`.
  bool apply({
    required TextEditingController name,
    required TextEditingController phone,
  }) {
    final isOurs = _lifted != null && phone.text == _lifted;
    final lifted = ClientNamePolicy.liftPhoneFromName(
      name: name.text,
      phone: isOurs ? '' : phone.text,
    );
    if (lifted == null) return false;

    if (lifted.name != name.text) {
      // Parked at the end, as `PhoneInputFormatter` does when its mask rewrites.
      name.value = TextEditingValue(
        text: lifted.name,
        selection: TextSelection.collapsed(offset: lifted.name.length),
      );
    }
    // `PhoneInputFormatter` does not run on a programmatic write, so the policy formats.
    phone.text = lifted.phone;
    _lifted = lifted.phone;
    return true;
  }

  /// Run first in a save: refills an emptied phone from the name, or else from
  /// the last lifted number (an embedded one has already left the name).
  void restoreOnSave({
    required TextEditingController name,
    required TextEditingController phone,
  }) {
    if (phone.text.trim().isNotEmpty) return;
    if (apply(name: name, phone: phone)) return;
    final lifted = _lifted;
    if (lifted != null) phone.text = lifted;
  }
}
