# 0127. Field primitives: `AttachedDropdown`, no counters, one label, switch rows

**Date:** 2026-09-12 (counter and "Attach" removed, owner call) · **Rules file:** `.claude/rules/frontend.md`

## Context
`AddressAutocompleteField` and `ClientPicker` were two copies of one dropdown shape, the second commented as
matching the first. Rows then diverged too: divided hand-built client rows vs bare `ListTile(dense: true)`
address rows. With no fill the panel borrowed the sheet colour and in dark was separated only by a
6%-white hairline; the client row painted ~36pt; and a `tapTargetSize.shrinkWrap` "Attach" `TextButton` sat
inside an `InkWell` doing the same action (pinned by `attached_dropdown_test.dart`). The appointment Notes
field was the only one showing a counter ("0/4000") while Materials (2000), Title (200) and Address (500)
enforced silently; without `showCounter` the cap routes through `LengthLimitingTextInputFormatter` instead
of `TextField.maxLength`, the same ceiling with no counter row. `AddressAutocompleteField` defaults its
label to `common_address` and reuses it as placeholder, so the form's own `formLabel` above it read
"Job address / Address / Address"; `AppointmentAddressField` now renders `formLabel` only on the
client-address pill branch, which has no field to carry one.
Four hand-built Settings tile+switch pairs drifted on whole-row toggling (a shrink-wrapped switch is
~31pt), and an `isLast` flag made each divider depend on later rows' visibility.

## Decision
One dropdown and row owner (`palette.sheetRow` fill, `cardStyle.pillShadow`, 48pt row, chevron only); no field passes `showCounter`; a
field that renders a label is not relabelled; Settings switch rows go through `SettingsSwitchTile` with
list-indexed dividers.

## Consequences
`showCounter` stays as a tested capability. Don't reintroduce a trailing label (`clients_attach` left both
ARBs).
