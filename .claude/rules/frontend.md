---
paths:
  - "lib/**"
  - "test/**"
---

# Frontend (Flutter / Material 3)

`ColorScheme`, `TextTheme` and `ThemeData` are the source of truth. Employee `colorValue` (int) drives appointment card borders and avatar backgrounds.

## Design tokens

`lib/core/theme/design_tokens.dart` owns the token classes and their rungs: `AppColors`, `AppSpacing`, `AppRadius`, `AppShadow`, `AppDuration`, `AppMotion` (shared `AnimationStyle`, e.g. `sheetStyle`).

- Never hardcode raw colours, spacing or radius in widgets, and never use static `AppColors.*` light tokens in `build()` — map through `Theme.of(context).colorScheme` so dark mode works.
- Import only `design_tokens.dart`, never a file under `core/theme/extensions/` — every `theme.<x>` getter resolves through its re-export. (ADR-0121)
- Put a role on `ColorScheme` only if Material's widgets read that slot implicitly; everything else goes on a `ThemeExtension` in `ThemeData.extensions` of both themes: `AppStatusColors` (`theme.statusColors`), `AppCardStyle` (`theme.cardStyle`, via `appCardDecoration`), `AppPalette` (`theme.palette`), `AppMonoType` (`theme.monoType`). (ADR-0121)
- Fill a destructive button with `palette.dangerFill`, never `scheme.error` (the foreground red, unreadable as a fill in dark); `colorScheme.primary` is the fill blue, `palette.primaryAccent` the text/icon blue. (ADR-0121)
- Use `ColorScheme.tertiary` for warning only; success reads `theme.statusColors.success`/`successContainer`/`onSuccessContainer`.
- Never branch on `isDark`/`Theme.of(context).brightness` for styling — add an extension field, set it in `.light` and `.dark`, read the getter. Only mode-selection UI may, resolving effective brightness via `isDarkMode(themeMode, MediaQuery.platformBrightnessOf(context))`, with `toggleTheme` flipping via `toggledThemeMode` (`core/theme/theme_notifier.dart`); `themeMode == ThemeMode.dark` misreads `system`. (ADR-0121)
- Use bundled `kFontSans`/`kFontMono`, never `google_fonts` or a raw `fontFamily` for numbers (`theme.monoType.data`/`.numeralKpi`/`.groupLabel`). Keep `AppMonoType.light`/`.dark` `static final` and `themes.dart`'s `extensions:` lists non-const. (ADR-0121)
- Store employee colour as the LIGHT-theme ARGB int, never a lifted value; render it with `crewColorOf` (exact dark map for the ten `AppColors.crewPalette` hues) and its text with `avatarForegroundFor` — white fails contrast on a lifted colour.
- Keep `AppColors.crewDefault` a `crewPalette` member, the nine `nav*` drawer hues a separate set (reordering the pool must not repaint the drawer), `decorativeHueRing` theme-independent, and every `AppRadius` rung even if unused. (ADR-0122)
- Treat any off-scale `EdgeInsets` optical nudge (e.g. 1–3, 5, 7, 9–15, 18, 20, 25, 30, 48, spN ± 2) as an accepted exemption, not a finding; everything else reaches for a token first. (ADR-0122)

## Widgets

- Use Material first; feature widgets live in the feature's `widgets/`. Check `lib/shared/widgets/` before creating one: Cancel/confirm questions use `showConfirmDialog` (`destructive:`); any other dialog uses `AppDialogFrame` + `DialogActionPair`, which deliberately doesn't wrap it. (ADR-0134)
- Keep `SkeletonList` (`skeleton_loader.dart`, stacked `SkeletonListTile`s) non-scrollable — two callers sit in a `SliverFillRemaining` that throws on a nested `ListView`. (ADR-0134)
- Use `WarningNote` for an amber caveat on a SUCCESS (`filled: false` inside a bordered surface), its icon on `onWarningContainer`; a failure stays `AuthBanner`/`composeErrorNotice`. (ADR-0134)
- Build detail views on `DetailSheetListView` (`showHandle:`, `handleGap`) with `QuickActionsRow`/`QuickActionButton` (only buttons whose data exists) and `InfoCard`/`InfoCardRow`; never a bare `ListView` or hand-rolled contact card. Omit empty sections rather than render "None".
- Use `AppTopBar` as every screen header, never a bare `AppBar`; `compact: context.isLandscape`. The calendar (`CalendarHeaderBlock`) is the one screen without it; don't generalise that. It is NOT an `AppBar`, so it must keep its `AnnotatedRegion` (via `overlayStyleFor`, never `theme.brightness`), the safe-area inset and no implicit `EndDrawerButton`. (ADR-0123)
- Keep `AppTopBar.preferredSize` an upper bound at `Breakpoints.maxTextScale` (2.2) — no top inset (`Scaffold` adds it), no `textScaler` param (every call site would default to `noScaling` and clip at 2×). (ADR-0123)
- Pass `textScaler: MediaQuery.textScalerOf(context)` at every `AppSearchBar` call site, or its context-free `preferredSize` clips at large text. (ADR-0123)
- Build every ghost control through `GhostControl` (`ghost_control.dart`): `kGhostTile` 38 painted, `kGhostTapTarget` 48 INSIDE the `InkWell`, tile is `Ink`; `GhostTone` `ghost`/`accent`/`selected`/`active`, a new tone only for a real variant. The agenda day/week toggle is two `GhostControl.icon` tiles, not a `SegmentedButton`. (ADR-0124)
- Give a pill's `Center` `widthFactor: 1`, or it fills `AppTopBar`'s `Flexible`; assert that in `ghost_control_test.dart`/`app_top_bar_test.dart`, not `app_header_pair_test.dart`. (ADR-0124)
- Give every screen `actions: const [AppHeaderPair()]` and `endDrawer: AppNavDrawer(...)`, with no `GlobalKey<ScaffoldState>`. The pill calls `goHomeToCalendar(context)`, never hand-rolled parts; `onBack` is `Navigator.maybePop`. (ADR-0124)
- Keep `AppNavDrawer` right-anchored, 284 px, at every size, rows from `drawerGroups(isAdmin:)` (`drawer_catalog.dart`), with no "is open" flag. A row leads with a 28×28 `drawerRowIcon(d)` chip on `crewColorOf(theme, drawerDotColor(d))` (the dark lift) at `theme.cardStyle.iconChipAlpha` (two separate switches over `AppDestination`) and keeps `sp8` padding to fit 48 px. (ADR-0124)
- Branch iOS-vs-Android LOOK only on `context.isCupertino` (`core/adaptive/adaptive.dart`), never `Platform.isIOS`/`defaultTargetPlatform`. A capability check may use `dart:io` (`AddressMapLauncher`); one guarding real logic injects `defaultIsIosPlatform` (`core/platform/ios_platform.dart`), never a private copy. (ADR-0125)
- Use `showAdaptiveActionSheet` for pick-one choosers, `AdaptiveProgressIndicator` for spinners (never a hand-rolled `SizedBox(CircularProgressIndicator)`), the `.adaptive` Material constructors and `AppScrollBehavior`. `showConfirmDialog` and `AppBackButton` are already adaptive; `showSeriesScopeDialog` alone has no Cupertino branch, and is no precedent. (ADR-0125)
- Use `BusyButtonIcon` for a busy `*.icon` button, `AnimatedLoadingButton` for submit, `destructiveOutlinedButtonStyle` for a destructive `OutlinedButton` and `accentPillButtonStyle` for the detail-header edit pill (`core/theme/button_styles.dart`).
- Let `EmployeeColorGrid` HIDE others' colours (never grey them; the selection stays visible); its custom dialog is swatches + shades, no wheel or hex.
- Render avatars with `AppAvatar` (`xs/sm/md/lg`), never hand-rolled; hand layout reads `AvatarSize.<x>.diameter`, never a copied number. `contrastingForegroundFor` stays the light-path primitive inside `avatarForegroundFor`.
- Pass `BrandMark(decorative: true)` beside a visible `brandName` wordmark only; never hand-roll a brand `Image`/`Icon` or localize `brandName`. (ADR-0134)
- Launch through `launchPhoneCall`, `AddressMapLauncher`, `EmailComposeLauncher` (built where `ref` lives), all over `launchExternalUri` — never a bare `launchUrl` (one lost its `try` and went FATAL). `AddressMapLauncher.showMapChoices` is the SnackBar carve-out and keeps its own `try`. (ADR-0128)
- Route a multi-stop run through `buildGoogleMapsRouteUrl` (`maxRouteStops` 10; extras drop silently, so warn) and `launchGoogleMapsRoute`, never `AddressMapLauncher`. (ADR-0128)
- Map strings to status only via `AppointmentStatus.fromRaw` (`appointment_status_values.dart`).
- Pick images via `pickAppointmentImages(context, ref)`, never `ImagePickerService`/`image_picker` from UI; a FORM adds them via `pickAndAddAppointmentImages`, which owns the post-await `context.mounted` re-check — the crew path `DetailsFieldRecordView._addPhotos` deliberately doesn't. Camera is gated by `MediaPermissionService`; display is `AppointmentImageCarousel` (read-only) / `PhotoPickerSection` (edit). (ADR-0129)
- Float `ScrollToTopButton` over a `PrimaryScrollScope` list (`threshold` 400; check `hasClients` before `offset`); a list under a floating control or FAB gets `kFloatingControlsClearance` (90) bottom padding; a new floating control composes `FloatingPill`. (ADR-0134)
- Pick a long/short label via `measureTextWidth` (`core/layout/`), passing the `Text`'s own `TextStyle`. (ADR-0134)
- Give each toured screen one `late final _tour = TourSteps(dest, isAdmin:)` and `stepBarIf` (the `stepIf` sibling) for the `bottom:` slot; never re-inline them. (ADR-0134)

## Layout

- Lay out with `Column`/`Row`/`Stack`/`Expanded`/`Flexible`/`Wrap`; `SizedBox` over `Padding` for size alone; extract deep trees. Touch targets ≥ 48×48.
- Never centre a child in a hug-width box with a `Container` `alignment` — it expands to the parent's width; the constraints already hold the tap floor. Use `Align(widthFactor: 1)` only when truly needed. (ADR-0130)
- Never put a `LayoutBuilder`-based widget (incl. `AutoSizeText`) under `IntrinsicHeight`/`IntrinsicWidth`; it throws in the intrinsic pass, so `AppointmentCard`'s title stays plain `Text`. (ADR-0130)
- Key a controlled `DraggableScrollableSheet`'s slot when an earlier sibling is conditional, or the old `dispose` detaches the new sheet and `animateTo`/`jumpTo` no-op. (ADR-0130)
- Wrap each simultaneously-mounted primary scrollable in `PrimaryScrollScope` (`core/layout/`), or the app scrollbar throws; `MasterDetailScaffold` scopes its panes. (ADR-0130)
- Give every FAB under `HubShell`'s `IndexedStack` a unique `heroTag`, declared in its tab screen: `addFab`, `clientsAddFab`, `employeesAddFab`. (ADR-0130)
- Gate through `core/layout/breakpoints.dart`, never a raw width. `isSplitLayout` (`isWide` || `isLandscape`) drives ONLY the calendar split; `isTwoPane` (shortest side ≥ 600) drives list master-detail, never `isSplitLayout` (a landscape phone is too narrow for a detail pane, and rotation never swaps one in). No nav rail or size-gated drawer. (ADR-0131)
- Fold dense rows on `context.isCompact` (width-only: `context.isNarrowWidth`); never re-inline the predicate.

## Notices

- Construct `NoticeListener` (in `MaterialApp.builder`, above the `Navigator`, where `Overlay.maybeOf` is null) with `navigatorKey: _navigatorKey` from `_PaulAppState`, or every notice is silently dropped. It fires the per-kind haptic; never add one at a call site.
- Never use `ScaffoldMessenger.showSnackBar` for feedback; only `account_exit_controller.dart`, `photo_upload_failure_listener.dart` and `address_map_launcher.dart` use a SnackBar, via `errorSnackBar(context, message, {action})`, never a hand-rolled `errorContainer` row.

## Forms & sheets

- Build every add/edit sheet on `FormSheetFrame` (`shared/widgets/sheets/`): fixed height, no grabber, its `SheetHeaderBar` (sole caller) carrying Cancel · title · verb as `TextButton`s, which keeps the disabled-verb assertion. Never nest it in a `DraggableScrollableSheet` — switch chrome above it, as `EventDetailsSheet` does on `isEditing`; destructive actions go in the scroll footer. (ADR-0126)
- Treat `FormSheetScaffold`, `EntityFormHeader` and `AuthBrandHeader` as deleted (a mention is a doc to fix); put a name in the frame's title. (ADR-0126)
- Keep `SheetHeaderBar`'s side slots MEASURED: both take the width of the WIDER label (`measureTextWidth`, each capped at 34%), which centres the title — never a flex (a `flex: 3/4/3` truncated "New Appointment" on the widest iPhone). (ADR-0126)
- Build divided panels through `SheetPanel`, never by hand; rows are `SheetFieldRow` (picked value), `SheetPanelRow` (child or trailing) or `LabeledTextField`, never a `ListTile` (it asserts in a `DecoratedBox`). (ADR-0126)
- Use `LabeledTextField` for free text: it owns `ClearTextButton` (opt out via `suffixIcon`/`readOnly`; `onCleared` keeps host state in sync; `placeholder` while empty) and the `errorText` shake (`AnimatedFormFieldWrapper`, null→non-null only, focus-stable) and fade. Never re-wrap or add a second animation; auth screens keep their own wrapper on bare `TextField`s.
- Pass no `showCounter` (the cap still applies); caps come from `TextLimits` (`core/validators/text_limits.dart`), never an inline integer. (ADR-0127)
- Use `AttachedDropdown` + `AttachedDropdownRow` for suggestion lists: it owns the fill, shadow and 48pt row, and the chevron is the whole affordance — no trailing label. (ADR-0127)
- Never relabel a field that renders its own label: `AppointmentAddressField` passes `calendar_jobAddress` down. (ADR-0127)
- Use `SettingsSwitchTile` for a Settings switch row (whole row toggles; `onTap` overrides it for a row that also navigates), and index card dividers off the row list, never an `isLast` flag. (ADR-0127)
- Keep `AuthScaffold`'s `AutofillGroup` and call `TextInput.finishAutofillContext()` only on success (sign-in, account setup, change password).
- Collapse any new animation to instant under `MediaQuery.disableAnimationsOf(context)` (see `_AnimatedFieldError`).
- Open a sheet from search via `SheetFocus` (`core/utils/sheet_focus.dart`): 80 ms settle before `showModalBottomSheet`, double unfocus 120 ms apart after.

## Accessibility & performance

- Make interactive elements keyboard/switch accessible, label icon buttons with `Semantics`; colour is never the only cue.
- Never clamp `MediaQuery.textScaler` without a visual reason; `StatusChip` caps itself at 1.3× (via `StatusPill`), so never wrap it in `noScaling`.
- Prefer `const`, `ListView.builder` and lifted state; Storage images show a placeholder while loading and handle errors.
- Never `ref.read` an `autoDispose` provider's value from a tap handler — it builds cold and returns `AsyncLoading`, read as empty data; watch in `build`. A permanent widget derives from `allUsersStreamProvider`, never `employeesStreamProvider`/`assignableEmployeesProvider` (a second session-long `users` listener), and re-applies `isActive && isAssignable`, as `CrewFilterButton` does (it carries invited/disabled users). (ADR-0132)
- Make a `Notifier` awaiting an autoDispose provider HOLD it (`ref.listen(p, (_, _) {})`, closed in `finally`), as `AddEventController.applyPrefill` does. (ADR-0132)
- Make a Retry over a combining provider invalidate the errored SOURCES, not the combiner, gating an invalidate on `hasError` where a healthy source would be re-billed — retry is off app-wide (`main.dart`); see `retryDashboardSources`, `_retryTeam`. Its widget test needs `retry: (_, _) => null` on the `ProviderScope`. (ADR-0132)
- Never construct a `DateFormat` in a cell/item builder; use `month_grid.dart`'s `longDateFormatFor`/`weekdayAbbrevFormatFor`/`_symbolsFormat` (keyed on `Localizations.localeOf`) or `DateUtilsHelper` (`Intl.defaultLocale`, context-free). Don't merge them; add a third only if one appears. (ADR-0133)
- `tool/check_rules.dart` (widget-timer) flags a raw `Timer` only under `/widgets/` and `/screens/`; the `Debouncer` rule (root `CLAUDE.md`) applies everywhere.
