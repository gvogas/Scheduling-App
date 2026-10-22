import 'package:flutter/widgets.dart';

import 'package:scheduling/features/clients/domain/policies/client_name_policy.dart';

/// Lifts a phone typed into the NAME field into the phone field (ADR-0095).
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
      // Cursor parked at the end, as `PhoneInputFormatter` does.
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

  /// Run first in a save: refills an emptied phone from the name or last lift.
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
