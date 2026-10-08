import 'package:flutter/widgets.dart';

import 'package:scheduling/features/clients/domain/policies/client_name_policy.dart';

/// Moves a phone number typed or pasted into the NAME field over into the
/// phone field, and takes it back out of the name.
///
/// This is the interactive form of the one-off backfill that had to fix
/// hundreds of clients entered as "Marc Tremblay 514-555-1234" with `phone`
/// left empty — nothing could dial those: not the detail view's Call button,
/// not the `clientPhone` denormalized onto each appointment, not the Wave
/// payload. Catching it at the keyboard is what stops the collection drifting
/// back into that shape.
///
/// Wired to the name field's `onChanged` in BOTH client sheets, so it fires on
/// a paste and on the tenth typed digit alike. It is quiet in the common case:
/// [ClientNamePolicy.liftPhoneFromName] returns null unless the phone field is
/// empty AND the name is nothing but a dialable number (any length), or embeds
/// exactly ten digits (a candidate containing `+` stays in the name). Once it
/// has fired the phone field is no longer empty, so it cannot fire twice or
/// fight the admin mid-edit.
///
/// Returns whether anything moved, so a caller can `setState`.
bool liftPhoneFromNameField({
  required TextEditingController name,
  required TextEditingController phone,
}) {
  final lifted = ClientNamePolicy.liftPhoneFromName(
    name: name.text,
    phone: phone.text,
  );
  if (lifted == null) return false;

  if (lifted.name != name.text) {
    // Parked at the end, the same honest behaviour `PhoneInputFormatter` takes
    // when its mask rewrites the string — re-deriving a caret offset across a
    // removed run is what makes this kind of edit jump unpredictably.
    name.value = TextEditingValue(
      text: lifted.name,
      selection: TextSelection.collapsed(offset: lifted.name.length),
    );
  }
  // Assigned, never appended: the guard above means the field was empty.
  // `PhoneInputFormatter` does not run on a programmatic write, so the value
  // arrives already formatted from the policy.
  phone.text = lifted.phone;
  return true;
}
