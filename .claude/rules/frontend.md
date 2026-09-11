---
paths:
  - "lib/**"
  - "test/**"
---

# Frontend (Flutter / Material Design)

## Design Tokens

Token file: `lib/core/theme/design_tokens.dart`. Never hardcode raw colors, spacing, or radius in widgets. The four `ThemeExtension`s live one level down in `core/theme/extensions/{app_card_style,app_status_colors,app_palette,app_mono_type}.dart` (each carries ~40 fields plus a `copyWith` and a `lerp`, which is what made the token file 965 lines) and are **re-exported by `design_tokens.dart`** — that single import path is a precondition of the split, not a nicety, since every `theme.palette` / `theme.statusColors` call site resolves its getter through it. Import the token file, never an extension file directly.

**Placement rule (redesign, 2026-07-30): a role goes on `ColorScheme` iff Material's own widgets read that slot implicitly; everything else goes on a `ThemeExtension`.** Where the design splits one Material slot in two, the slot takes the variant the framework's implicit consumers need and the extension takes the other. So `colorScheme.primary` is the saturated **fill** blue (FilledButton, FAB, app bar) while `palette.primaryAccent` is the text/icon blue; conversely `colorScheme.error` is the lifted **foreground** red (input error text/borders) while `palette.dangerFill` is the destructive fill — **a destructive filled button must read `palette.dangerFill`, never `scheme.error`**, or it is unreadable in dark. Four extensions are registered on both themes: `AppStatusColors` (`theme.statusColors`), `AppCardStyle` (`theme.cardStyle`), `AppPalette` (`theme.palette`), `AppMonoType` (`theme.monoType`).

**Fonts are bundled asset families, not `google_fonts`** (the package is gone): `kFontSans` = Instrument Sans, `kFontMono` = IBM Plex Mono. A call site never writes a raw `fontFamily` for numbers — it writes `theme.monoType.data` / `.numeralKpi` / `.groupLabel` etc. `AppMonoType.light`/`.dark` are `static final`, not `const`, because Dart has no const functions and a const initializer cannot construct a `TextStyle` from a constructor *parameter*; that is why the `extensions:` lists in `themes.dart` are non-const. Don't "restore" the const.

**Employee colour is STORED as the light-theme ARGB int.** Render it through `crewColorOf(theme, storedInt)` (exact per-theme map for the ten `AppColors.crewPalette` hues, generic HSL lift for anything custom) and pick its foreground with `avatarForegroundFor(theme, background)` — white on a lifted crew colour fails contrast at avatar sizes. **Never store a lifted value.**

| Token class | Use for |
|---|---|
| `AppColors` | semantic color names; use `ColorScheme` tokens in `build()` for dark-mode safety |
| `AppSpacing` | `sp4` / `sp8` / `sp12` / `sp16` / `sp24` / `sp32` |
| `AppRadius` | `r8` / `r12` / `r16` / `r20` / `r24` / `rFull` |
| `AppShadow` | elevation shadows |
| `AppDuration` | animation durations |
| `AppMotion` | shared `AnimationStyle` (e.g. `sheetStyle` for bottom sheets) |

**Off-scale `EdgeInsets` values are an ACCEPTED EXEMPTION, not a backlog** (owner call, 2026-09-05). Roughly two dozen sites pad at 5, 9, 10, 11, 13, 14, 15, 18, 20, 25 or 48 — several mixing a token value with an off-scale one in the same `fromLTRB` (`inline_month_calendar.dart`, `calendar_month_grid.dart`, `app_nav_drawer.dart`). They are deliberate optical nudges with no unambiguous token to map to, and adding those steps to `AppSpacing` would destroy the scale that makes it useful. Every audit since 2026-08 has re-found them; this paragraph is where that stops. The rule above is unchanged for everything else: reach for a token first, and go off-scale only for an optical correction you would have to undo by hand.

Never use static `AppColors.*` light tokens directly in `build()` — always map through `Theme.of(context).colorScheme` so dark mode works.

**`ColorScheme.tertiary` is the warning palette (amber) in both themes — never use it for success.** Success-meaning surfaces (banners, badges, notices, checkmarks) read `theme.statusColors.success` / `successContainer` / `onSuccessContainer` (the `AppStatusColors` extension); tertiary is only for warning/attention accents.

**Never branch on `isDark` / `Theme.of(context).brightness` for styling.** A
light↔dark difference that `ColorScheme` can't express on its own (shadow vs.
border, mode-specific decoration) lives in a `ThemeExtension` registered on
`ThemeData.extensions`, read through a `theme.<x>` getter — see `AppStatusColors`
(`theme.statusColors`) and `AppCardStyle` (`theme.cardStyle`, wrapped by
`appCardDecoration(theme, ...)`). To add a per-theme value: add a field to the
extension, set it in both `.light`/`.dark`, and read the getter — no brightness
check at the call site. The **only** legitimate `isDark` is mode-selection UI
(the dark-mode toggle), never appearance — and there it must resolve the
*effective* brightness via `isDarkMode(themeMode, MediaQuery.platformBrightnessOf(context))`
(`core/theme/theme_notifier.dart`), NOT `themeMode == ThemeMode.dark`, or the
switch mis-reads the default `system` mode on a dark phone and needs two taps.
`toggleTheme` flips via `toggledThemeMode(...)` for the same reason.

## Design Principle

Material Design 3 (Flat / Elevation). Use `ColorScheme`, `TextTheme`, and `ThemeData` as the source of truth. Employee `colorValue` (int) drives appointment card borders and avatar backgrounds.

## Widget Framework

- Material widgets first. Reach for custom widgets only when Material doesn't fit.
- Shared widgets live in `lib/shared/widgets/`. Feature-specific widgets live in the feature's `widgets/` folder.
- `AppTopBar` (`shared/widgets/app_bars/`) is the standard screen header, and **it is not an `AppBar` any more** (2026-09-11, the "fresh" redesign). It paints `theme.scaffoldBackgroundColor` with a `displayLarge` title, an optional `count` beside it in `monoType.metric`/`palette.textTertiary`, ghost controls, and no bar and no divider; `compact: context.isLandscape` drops the title onto the 48px controls row as `titleLarge`. It still `implements PreferredSizeWidget` and every screen still uses it — never hand-build a bare `AppBar`. **Dropping the `AppBar` means it reproduces three things the framework was giving it**, and all three are load-bearing: the `AnnotatedRegion<SystemUiOverlayStyle>` (brightness ESTIMATED off the painted surface, never branched on `theme.brightness`), the safe-area inset, and — because `actions` no longer suppresses anything — the absence of an implicit `EndDrawerButton`.
  **`preferredSize` is an upper BOUND, not the rendered height, and that is deliberate.** The getter has no `BuildContext`, so it cannot see the text scaler; it reserves the text-driven rows at 2.2 (the cap `main()` composes to) and the header renders its real rows inside that. Two `Scaffold` facts make this correct rather than sloppy, both worth knowing before anyone "tightens" it: `Scaffold` adds `MediaQuery.paddingOf(context).top` ITSELF (`scaffold.dart`, `_appBarMaxHeight`), so including the inset here double-counts it; and `contentTop` comes from the **laid-out** height (`layoutChild(_ScaffoldSlot.appBar, …).height`), so over-reserving leaves no gap and only *under*-reserving clips. The bound is also what bounds the `Flexible` title row — a `RenderFlex` with unbounded height would throw. Don't add a `textScaler` parameter to "fix" it: 10 call sites would default it to `noScaling` and clip at 2×.
  **One screen has no `AppTopBar` at all: the calendar** (`CalendarHeaderBlock`, P2). A `PreferredSizeWidget`'s height is fixed per build, so it cannot host the week strip that rises in and out on collapse. That block now paints the same page colour and ghost controls as the header, and sets its own `AnnotatedRegion` the same way. Don't generalise the exception.
- **Every screen passes `actions: const [AppHeaderPair()]` and `endDrawer: AppNavDrawer(...)`.** The pair (Calendar pill + hamburger) is the uniform header chrome, styled as ghost controls since 2026-09-11 — `scheme.surface` fill, 1px `scheme.outlineVariant` border, `scheme.onSurface` glyph, `AppRadius.rFull`, a 38px painted box inside a 48px tap target, and the pill's calendar glyph alone in `scheme.primary`. Putting it in `actions` **used to** be what suppressed Flutter's automatic `EndDrawerButton`; since `AppTopBar` stopped being an `AppBar` there is no implicit button to suppress, so that is no longer the reason to do it — uniformity is. It resolves its host through `Scaffold.of(context)`, so **no screen needs a `GlobalKey<ScaffoldState>`** — don't reintroduce one. The Calendar pill calls `goHomeToCalendar(context)`, the one canonical go-home gesture (close drawer → calendar tab → collapse the pushed stack); never hand-roll its parts. Pushed screens' `onBack` is a plain `Navigator.maybePop` — back means back, the pill covers go-home. `AppNavDrawer` is right-anchored, 284 px, and is the nav surface at **every** screen size; its rows come from `drawerGroups(isAdmin:)` in `features/navigation/domain/drawer_catalog.dart`. A closed drawer's child is never built, so watching `.autoDispose` count providers in its body is free — do **not** add an "is open" flag. **A row's leading is a 28×28 tinted icon chip** — `drawerRowIcon(d)` on `drawerDotColor(d)` at `theme.cardStyle.iconChipAlpha`, the same idiom as `InfoCardRow` — so colour is never a row's only cue. Icon and colour are two separate exhaustive switches over the sealed `AppDestination`, not one record: a row's icon is stable while its hue is decoration. The row padding is `sp8`, not `sp12`, **specifically so the 28px chip fits inside the existing 48 px minimum** rather than growing the drawer; don't "restore" `sp12`.
- `AppointmentCard`, `StatusChip`, `AppAvatar`, `SkeletonLoader`, `SkeletonList` (N stacked `SkeletonListTile`s — the standard list loading state; deliberately NOT scrollable, since two of its callers sit inside `infinite_scroll_pagination`'s `SliverFillRemaining`, which asks its child for intrinsics and throws on a nested `ListView`. It was hand-built at each call site and had already drifted on the row gap), `AppEmptyState`, `AppSearchBar` (the one search-field style — Clients/History/Employees all use it), `EmployeeColorGrid`, `SectionLabel` (uppercase mini-header), `showConfirmDialog` (Cancel/confirm dialog; `destructive:` toggles the error-filled confirm), `AppDialogFrame` (`shared/widgets/dialogs/` — the bare dialog SHELL: title, scrollable body, action row, and the one inset value with no token behind it. It is the frame under a dialog that is NOT a Cancel/confirm question, so it does not replace `showConfirmDialog` and deliberately does not wrap it; the three call sites that had the same twelve lines each are the booking-conflict, series-scope and time-off clash dialogs) — use these before creating new ones.
- `EmployeeColorGrid` **hides** colors taken by another employee (never grey/disable them; the current selection always stays visible), and its custom dialog is a tap-a-swatch palette + shades only — don't reintroduce the color wheel or hex-code field.
- `ClearTextButton` (`shared/widgets/fields/`) is the one clear-"x" suffix — `LabeledTextField` adds it to every editable field automatically (a custom `suffixIcon` or `readOnly` picker field opts out); its `onCleared` must keep host state/validation in sync, and the optional `placeholder` renders while the field is empty. Never hand-roll a suffix clear button.
- `AttachedDropdown` (`shared/widgets/fields/`) is the bordered suggestion list
  that attaches under a text field — margin, border, radius and clip in one
  place. `AddressAutocompleteField` and `ClientPicker` both build on it; they
  were two hand-written copies of the same shape, the second carrying a comment
  asserting it matched the first, which is the drift `SheetPanel` already
  exists to stop. It owns the CHROME only: each caller still builds its own
  rows, so the address field's plain list and the client picker's
  divider-indexed one with its fallback caption stay different on purpose.
- `BusyButtonIcon` (`shared/widgets/primitives/`) is the leading slot for a `*.icon` button that swaps to a spinner while busy — use it instead of hand-rolling `isBusy ? SizedBox(CircularProgressIndicator) : Icon(...)` (the button keeps its own styling and disables itself). `AnimatedLoadingButton` (`core/animations/`) remains the primary/submit button (whole label↔spinner swap). For a destructive (delete/cancel) `OutlinedButton`, style it with `destructiveOutlinedButtonStyle(context, {minimumSize})` (`core/theme/button_styles.dart`) rather than repeating the `scheme.error` foreground + border.
- **Platform adaptivity is one seam: `context.isCupertino`** (`core/adaptive/adaptive.dart`;
  reads `Theme.of(context).platform`, NOT `defaultTargetPlatform`, so tests force the look via
  `ThemeData(platform:)`). It is the single source of truth for iOS-vs-Android UI branching —
  route new platform branches through it; never scatter `Platform.isIOS` / `defaultTargetPlatform`
  at call sites. The one exception is real device **capability** (not look) — e.g. which map apps
  exist uses `dart:io Platform.isIOS` in `AddressMapLauncher`. A capability gate that guards
  REAL LOGIC takes `defaultIsIosPlatform` (`core/platform/ios_platform.dart`) as an injected
  `bool Function()` instead, so the harness can reach behind it: `flutter test` runs on the host,
  where a bare `Platform.isIOS` returns first and leaves everything after it untestable — on the
  only platform that ships. It lives in `core/` because two of its callers already import each
  other; don't re-declare a private copy beside a third (`widget_sync_service.dart` carried one
  until 2026-08-22). Shared adaptive widgets, all
  Android-unchanged: `showAdaptiveActionSheet` (`core/adaptive/adaptive_action_sheet.dart` —
  `CupertinoActionSheet` on iOS, Material bottom sheet on Android; the one "pick one option"
  chooser), `AdaptiveProgressIndicator` (busy spinner — `BusyButtonIcon` / `AnimatedLoadingButton`
  already delegate to it; don't hand-roll `SizedBox(CircularProgressIndicator)`), and
  `AppScrollBehavior` on `MaterialApp.scrollBehavior` (iOS `CupertinoScrollbar`, vertical
  scrollables only). Prefer the `.adaptive` Material constructors (`Switch.adaptive` /
  `SwitchListTile.adaptive` with `activeTrackColor: scheme.primary`, `RefreshIndicator.adaptive`)
  over the plain ones. `showConfirmDialog` and `AppBackButton` already render their Cupertino
  variants on iOS. **One design-mandated exception: `showSeriesScopeDialog` has NO Cupertino
  branch** (P2). The design puts a consequence line under each scope option ("12 remaining visits
  through 26 Jan") and an action sheet cannot render one. That is a single exception, not a policy
  change — don't use it to justify dropping other Cupertino branches.
- **Sheet chrome added by P2** — `FormSheetFrame` (`shared/widgets/sheets/`) is the add/edit form shell: a fixed-height sheet whose bar carries **Cancel · title · primary verb**, no grabber. **`SheetHeaderBar` IS that bar and `FormSheetFrame` is its ONLY caller** — there is no separate close-button sheet header, and the detail sheets (appointment, client, employee) carry no header bar at all: they are a `DetailSheetListView` with a drag handle. Since 2026-09-11 the bar speaks the same fresh vocabulary as `AppTopBar`: **no coloured band and no divider** (it sits on the sheet's own `surfaceContainerLowest`), a `headlineLarge` title in `scheme.onSurface`, and Cancel/verb painted as ghost tiles — `scheme.surface` fill, 1px `scheme.outlineVariant` border, `AppRadius.rFull`, a 38px painted box that `tapTargetSize.padded` lifts to the 48px tap floor. Both stay `TextButton`s, which is what keeps the disabled-verb assertion meaningful; the verb's label keeps `palette.primaryAccent` (`textMuted` disabled) because it is the accented control, the way the header pill keeps its calendar glyph in `scheme.primary`. It **is** a sheet, so never nest it inside another `DraggableScrollableSheet` — switch chrome above it, the way `EventDetailsSheet` picks the frame by `isEditing`. Destructive actions go in the scroll footer, never the bar. `SheetPanel` (`shared/widgets/cards/`) is the white divided-row container inside a form sheet — **build one through it, never by hand**: three private copies appeared in one release (the selected-client card, the picker's result panel, the previous-job-address list) and had already drifted on corner radius, two falling through to `appCardDecoration`'s `r12` beside an `r16` sibling in the same section, while a fourth widget in the same diff called `SheetPanel` correctly. It also indexes its dividers, where a hand-built copy compared record VALUES against `rows.first` and would drop a divider between two equal rows; `SheetFieldRow` (`shared/widgets/fields/`) is the label-over-value picker row used for dates and times — free-text fields keep `LabeledTextField`, which owns the error shake and the clear button. `SheetPanelRow` (`shared/widgets/cards/`) is the third row shape: label-over-**child** (a chip strip) or label-beside-**trailing** (a switch), for a row that has no picked *value* — a `SheetFieldRow` with an empty value renders a blank second line where the value belongs. It was private to `edit_person_sheet.dart` until the AVAILABILITY panel appeared on My details too (P5, 2026-08-10); both screens must render that panel identically. **Never use a `ListTile` family widget inside a `SheetPanel`** — the panel paints its own decoration, and `ListTile` asserts ("background color or ink splashes may be invisible") when its background sits inside a `DecoratedBox`. `KeyValuePanel` (`shared/widgets/cards/`) is the read-only detail sheet's 70px mono key column. **`FormSheetFrame` is the ONLY form-sheet chrome** — the older `FormSheetScaffold` was retired once P3/P4 migrated the last client and employee sheets, and `EntityFormHeader` went with the edit forms that used it. Both have zero declarations and zero call sites; the only survivor is the tombstone comment in `form_sheet_frame.dart:16` (the stale `add_client_sheet_test.dart` comment this used to name was fixed, and reads `FormSheetFrame` now). This bullet said "**`FormSheetScaffold` survives**" long after it did not, while the Forms & sheets section below told you to build new sheets on it — so build on `FormSheetFrame`, and treat a mention of either retired class as documentation to correct rather than an API to find. `InfoCard` IS live and untouched.
- `SettingsSwitchTile` (`settings/widgets/cards/settings_tile.dart`) is the
  Settings row whose control is a switch, and the WHOLE ROW toggles it — a
  shrink-wrapped `Switch.adaptive` is about 31pt, under both tap minimums, on
  the row whose label is what you are aiming at. Four hand-built tile+switch
  pairs had already drifted on that property, leaving two halves of one screen
  at different row heights. `onTap` overrides the row toggle for a row that
  also navigates (location sharing opens a screen; only its switch flips
  sharing). **A settings card indexes its dividers off its row LIST**, the way
  `SheetPanel` does — the `isLast` flag it replaced made every row's divider
  depend on whether some LATER row was visible, so adding one meant editing
  every earlier row's condition, and the flag was already dead at four sites.
- `DetailSheetListView` (`shared/widgets/sheets/`) is the standard scrollable shell for a detail view shown in a bottom sheet (`showHandle: true`) or a master-detail pane — standard padding, optional drag handle, keyboard-inset-aware bottom gap (`handleGap` tunes the post-handle spacing). Use it for new detail views instead of a bare `ListView`.
- Detail-view building blocks are shared by the client and appointment view
  bodies: `QuickActionsRow` + `QuickActionButton` (`shared/widgets/primitives/`,
  tinted Call/Email/Directions tiles — pass only the buttons whose data exists)
  and `InfoCard` + `InfoCardRow` (`shared/widgets/cards/`, a bordered card of
  tappable rows with tinted icon chips). Reuse these for any new detail surface;
  don't hand-roll a contact card or action-button row. The actions launch
  through the shared helpers — `launchPhoneCall` (`core/launchers/`),
  `AddressMapLauncher`, `EmailComposeLauncher` — built where `ref` lives.
  Those all delegate to **`launchExternalUri`**
  (`core/launchers/external_uri_launcher.dart`), the single launch + catch +
  `logger.warn(tag)` + error-notice body. Never hand-roll a bare `launchUrl`:
  the copies it replaced had drifted, and one had lost its `try`/`catch`, so a
  thrown `launchUrl` escaped to the zone handler as a FATAL instead of a
  notice. `AddressMapLauncher.showMapChoices` is the one carve-out (it surfaces
  via a sanctioned SnackBar, not a notice) and still wraps its own `try`.
  Read-only detail bodies **omit empty sections** entirely rather than rendering
  "None" placeholders.
- **Multi-stop routing** is a separate seam from single-address launching:
  `buildGoogleMapsRouteUrl` (`maps/domain/route_url_builder.dart`) builds one
  directions URL through the stops in order (`maxRouteStops = 10` — Google's
  9 waypoints + 1 destination cap; extra stops are silently dropped, so warn
  the user), and `launchGoogleMapsRoute` (`core/launchers/route_map_launcher.dart`)
  opens that prebuilt URI. Apple Maps has no multi-stop URL scheme, so this is
  Google-only; `AddressMapLauncher` remains the per-stop chooser for a single
  address. Don't route a multi-stop run through `AddressMapLauncher`.
- `AppAvatar` (sizes `xs/sm/md/lg`) resolves its background through `crewColorOf` and its foreground through `avatarForegroundFor` (design_tokens) — do not hand-roll initials-on-color circles or the black/white contrast ternary. `contrastingForegroundFor` survives as the light-path primitive inside `avatarForegroundFor`. A caller that must lay avatars out by hand (the appointment card's overlapped crew stack, which can't use `LayoutBuilder` under `IntrinsicHeight`) reads `AvatarSize.<x>.diameter` — never a local copy of the number, which drifts silently with no compile error.
- `BrandMark` (`shared/widgets/branding/brand_logo.dart`) is the app logo
  (`assets/images/brand_mark.png`, the 512px derivative — the 1254px
  `icon.png` master is deliberately NOT bundled; see `assets/images/README.md`)
  — never hand-roll an `Image`/`Icon` for branding.
  Pass `decorative: true` where a visible `brandName` wordmark sits beside it
  (splash, onboarding bar) so a screen reader doesn't read the name twice; leave
  it on where the mark is the only brand cue (auth header). Auth screens get the
  mark from the hero header in `auth_scaffold.dart` (P4b — `AuthBrandHeader`
  is deleted, along with the `EntityFormHeader` the retired edit forms used);
  `brandName` is a proper noun — never localize it.
- `WarningNote` (`shared/widgets/feedback/`) is the amber "heads up, but nothing
  failed" box — a caveat attached to an action that *succeeded*. A real failure
  stays `AuthBanner` / `composeErrorNotice`. Its icon reads `onWarningContainer`,
  the same token as the text beside it; the hand-rolled copies it replaced had
  already drifted to `status.warning`, which is the standalone accent and does
  not hold contrast on the container fill.
  **`filled: false` is the same note without the container**, for a caption
  already inside a bordered surface where a second amber panel reads as a
  nested box: the booking-conflict dialog and the assignee picker's
  nobody-free line. Both had grown their own hand-rolled copy of exactly that
  row — which is the drift this class exists to stop — so take the flag rather
  than spelling a third.
- `accentPillButtonStyle(context)` (`core/theme/button_styles.dart`) is the
  tinted accent pill that opens an edit sheet from a detail header. The client
  detail's and the team profile card's are the same control — style both through
  it, the way destructive outlined buttons go through
  `destructiveOutlinedButtonStyle`.
- `AppointmentStatus.fromRaw` (status_chip.dart) is the only string→status mapper — never add a per-widget switch.
- **Image picking goes through `pickAppointmentImages(context, ref)`**
  (`calendar/widgets/sheets/image_source_picker.dart`) — never call
  `ImagePickerService` / `image_picker` directly from UI. **A FORM adds them
  through `pickAndAddAppointmentImages` beside it**, which owns the pick, the
  post-await `context.mounted` re-check and the notice naming what the per-job
  cap dropped. The pick is the longest await in the app — an OS action sheet
  and then the camera or Photos picker — so the form can be gone when it
  returns; the two hosts spelled that out separately and had already drifted on
  which `mounted` they checked. The CREW path
  (`DetailsFieldRecordView._addPhotos`) deliberately does not use it: it
  clamps against the job's stored count as well as the per-pick cap and
  uploads in the background rather than staging into form state. It offers Camera /
  Gallery; camera is gated by `MediaPermissionService` (`permission_handler`),
  gallery uses the OS photo picker (no permission needed). Read-only appointment
  photos render as an `AppointmentImageCarousel` (`smooth_page_indicator`);
  edit mode uses the `PhotoPickerSection` thumbnail strip.

- **`TourSteps`** (`feature_tour/domain/tour_steps.dart`) owns a screen's step
  ids, keys and `step()` wrapper. Six screens had a copy of the trio that had to
  stay in sync (`keys[id]!` force-unwraps; `indexOf`/`length` feed "step N of
  M") and Settings had already drifted. One `late final _tour = TourSteps(dest,
  isAdmin:)` per screen — don't re-inline it. **The app bar's `bottom:` slot
  uses `stepBarIf`**, the `PreferredSizeWidget` sibling of `stepIf`: without it
  that one slot escaped the class's ownership and Clients, History and Team each
  re-spelled the same six-line `has(id) ? TourShowcaseBar(...) : bar` block by
  hand.

## Layout

- Use `Column`, `Row`, `Stack`, `Expanded`, `Flexible`, `Wrap` for layout. Prefer `SizedBox` over `Padding` when only size is needed.
- Touch targets: minimum 48×48 logical pixels (Material guideline).
- Avoid deeply nested widget trees — extract into named methods or sub-widgets.
- **Responsive:** `Breakpoints.tablet = 840`, `tabletShortestSide = 600`,
  `expanded = 1200`. Context getters:
  `isWide` (`width ≥ 840`), `isLandscape` (orientation),
  `isSplitLayout` (`isWide || isLandscape`), and
  `isTwoPane` (`MediaQuery.shortestSide ≥ 600`). Two DIFFERENT gates, don't
  conflate them:
  - `isSplitLayout` drives the **calendar Split chrome** only, so
    **landscape phones AND tablets** render the calendar side-by-side (month
    grid | day agenda, details in a sheet — it has no detail pane) while
    portrait phones stay single-column. The **nav rail is gone** (deleted
    2026-07-30 with `AdaptiveShell`, `Breakpoints.expanded` and `isExpanded`);
    `AppNavDrawer` is the nav surface at every size, so `isSplitLayout` no
    longer gates any nav chrome. Don't reintroduce a rail or a size-gated drawer.
  - `isTwoPane` drives the **list-screen master-detail** (`MasterDetailScaffold`,
    list | detail side by side). It's **tablet-class only and
    orientation-independent** (shortest side ≥ 600): a landscape phone reports
    `isSplitLayout` but NOT `isTwoPane` — it's too narrow for a
    readable detail pane, so it falls back to the single list + a pushed detail
    sheet, and rotating a phone never swaps a pane in. Gate every list
    master-detail on `isTwoPane`, never on `isSplitLayout` or a raw width.
  In landscape, app bars slim down via `AppTopBar(compact: true)`.
- **Compact / narrow folding:** dense rows (cards, headers, action bars, detail
  rows) that stack vertically on small phones or large text read
  `context.isCompact` (`width < Breakpoints.compactWidth` (360) `|| textScale >
  Breakpoints.compactTextScale` (1.4)); `context.isNarrowWidth` is the
  width-only variant for layouts that fold on screen width alone. Sheets that
  grow on short (landscape-phone) viewports gate on
  `Breakpoints.shortViewportHeight` (700). All live in `core/layout/breakpoints.dart`
  beside `isWide`/`isSplitLayout` — never re-inline the `width<360 || scale>1.4`
  predicate at a call site.
- **No `LayoutBuilder`-based widget under `IntrinsicHeight`/`IntrinsicWidth`.**
  `LayoutBuilder` can't return intrinsic dimensions, so it throws
  `LayoutBuilder does not support returning intrinsic dimensions` during the
  intrinsic pass — which in release builds surfaces later as a paint-time
  `Null check operator used on a null value` on the enclosing scroll viewport
  (the aborted layout leaves slivers with null geometry). `auto_size_text`'s
  `AutoSizeText` wraps an internal `LayoutBuilder`, so it cannot live inside an
  `IntrinsicHeight` subtree. `AppointmentCard` uses `IntrinsicHeight` to stretch
  the employee-color bar, so its title stays a plain `Text` — don't swap it back
  to `AutoSizeText`.
- **Multiple primary scrollables alive at once → wrap each in
  `PrimaryScrollScope`** (`core/layout/primary_scroll_scope.dart`). A route
  offers one `PrimaryScrollController`, and the app-wide `Scrollbar`/
  `CupertinoScrollbar` (`AppScrollBehavior`) throws "attached to more than one
  ScrollPosition" if two controllerless primary `ScrollView`s attach to it. This
  happens in the hub's `IndexedStack` of always-alive tabs and in the calendar /
  master-detail splits — each tab and each pane is already scoped; scope any new
  simultaneously-mounted scroll surface the same way. `MasterDetailScaffold`
  scopes its two panes for you.
- **Every FAB inside the persistent hub (`routes/hub_shell.dart`) needs a unique
  `heroTag`.** The `IndexedStack` keeps every tab's `Scaffold` (and FAB) mounted
  at once, so a default/shared hero tag collides ("multiple heroes share the same
  tag"). The tags are declared in the tab screens the hub keeps mounted (not in
  `hub_shell.dart` itself). Existing tags (5): `addFab`
  (`main_calendar_screen.dart`), `clientsAddFab` (`clients_screen.dart`),
  `employeesAddFab` (`employees_screen.dart`), and `liveMapRosterFab` +
  `liveMapRecenterFab` (`live_map_screen.dart`). `todayFab` retired in P2 — the
  Today control is now a plain `Material` pill, not a FAB.
- **`AppSearchBar` call sites must pass `textScaler: MediaQuery.textScalerOf(context)`.**
  Its `preferredSize` has no `BuildContext`, so without the scaler the app-bar
  bottom slot reserves fixed height and clips the field at large text sizes.

## Notices & user feedback

- Notices slide in from the **top** of the screen via `Overlay` (`NoticeListener`).
  `NoticeListener` is in `MaterialApp.builder`, which sits above the `Navigator`,
  so `Overlay.maybeOf(context)` returns null. It must be constructed with
  `navigatorKey: _navigatorKey` (from `_PaulAppState`) to reach the Navigator's
  overlay. Omitting it silently suppresses all notices.
- `NoticeListener` also fires the haptic cue per notice kind (medium impact for
  error, light otherwise) — never add a call-site haptic alongside a notice.
- Do not call `ScaffoldMessenger.showSnackBar` for user feedback — use
  `ref.read(noticeServiceProvider).success/error/info(message)` instead.
  The three sites that must use a SnackBar (account-disabled in
  `core/app/account_exit_controller.dart`,
  photo-upload in `core/app/photo_upload_failure_listener.dart`, map-launch in
  `features/maps/address_map_launcher.dart`)
  build it through `errorSnackBar(context, message, {action})`
  (`shared/widgets/feedback/`) — don't hand-roll the `errorContainer` + icon `Row`.

## Forms & sheets

- `FormSheetFrame` (`shared/widgets/sheets/`) is the chrome for an add/edit
  form shown in a bottom sheet — a FIXED-HEIGHT sheet whose `SheetHeaderBar`
  carries **Cancel · title · primary verb**, and no grabber. Use it for new form
  sheets (it's the form-sheet sibling of `DetailSheetListView`), and never nest
  it inside another `DraggableScrollableSheet`: it *is* a sheet. Destructive
  actions go in the scroll footer, never in the bar.
  **`FormSheetScaffold` and `EntityFormHeader` are DELETED** (P3/P4, P4b) —
  this bullet named both as the thing to build on for a long time after. There
  is no replacement for `EntityFormHeader`; the surfaces that had one now put
  the name in the frame's title.
- Text-field length caps live in `lib/core/validators/text_limits.dart`.
  Use the constants via `LabeledTextField(maxLength: TextLimits.x)` —
  don't hardcode integer caps at call sites.
- `AuthScaffold` wraps every auth form in an `AutofillGroup`, and the sign-in /
  create-account success paths commit it via `TextInput.finishAutofillContext()`
  so OS password managers offer to save the credentials — keep both halves when
  touching auth flows (commit only on success, never on a failed attempt).
- **Field error animation is built into `LabeledTextField`** — setting
  `errorText` shakes the field (`AnimatedFormFieldWrapper`: controller-based,
  fires only on null→non-null transitions, tree-stable so keyboard focus
  survives) and fade-slides the error row in/out. Never re-wrap call sites or
  add a second animation; auth screens keep their own `AnimatedFormFieldWrapper`
  usage around bare `TextField`s.
- Any new animation must collapse to instant when
  `MediaQuery.disableAnimationsOf(context)` is true (see the wrapper and
  `_AnimatedFieldError` for the pattern).
- Sheet-from-search: 80 ms settle before `showModalBottomSheet`;
  double unfocus with 120 ms gap after sheet closes.

## Accessibility

- All interactive elements must be keyboard/switch accessible.
- Provide `Semantics` labels on icon buttons and custom interactive widgets.
- Respect `MediaQuery.textScaler` — never clamp text scale without a visual
  reason. Sanctioned exception: `StatusChip` internally caps its label scaling
  at 1.3× — never wrap a `StatusChip` call site in
  `MediaQuery(textScaler: noScaling)`; the chip handles it.
- Color must never be the sole indicator of state.

## Performance

- `const` constructors wherever possible.
- Large lists: use `ListView.builder`, not `ListView(children: [...])`.
- Avoid rebuilding heavy subtrees — use `const` or lift state.
- Images from Firebase Storage: show `SkeletonLoader` while loading, handle errors gracefully.
- **Never `ref.read` an `autoDispose` provider's value from a tap handler.**
  Nothing is subscribed at that moment, so the read BUILDS it cold, gets
  `AsyncLoading` back, takes the `?? []` branch and disposes it again — a
  failure that looks like empty data, is identical on every tap rather than
  only the first, and logs nothing. `CrewFilterButton` shipped this: its sheet
  offered "All crew" and nobody else, always. Watch the value in `build` and
  pass it into the handler.
  **Then pick WHICH stream to watch by how long the widget lives.** A permanent
  widget must not watch `employeesStreamProvider` (or anything derived from it,
  such as `assignableEmployeesProvider`): it is `autoDispose` precisely so a
  transient sheet cannot pin a SECOND live `users` listener for the session, and
  a widget on a `HubShell` tab is alive as long as the session is. The calendar
  header already watches `allUsersStreamProvider` for its colour and name maps,
  so deriving from that one is warm at tap time AND free. A sheet or dialog is
  transient and should keep using the autoDispose stream.
  **A `Notifier` that awaits one must HOLD it** — `ref.listen(p, (_, _) {})`
  around the await, closed in a `finally` — rather than trusting whatever
  happens to be watching from the widget layer. `AddEventController.applyPrefill`
  is the reference; the tell that it was missing was a keep-alive in the unit
  test with no production counterpart.
- **`DateFormat` is memoized per locale** (`calendar/domain/month_grid.dart`:
  `longDateFormatFor`, `weekdayAbbrevFormatFor`, `_symbolsFormat`). Constructing
  one verifies the locale and parses a skeleton into pattern fields, and the
  calendar built a fresh one PER DAY CELL for a semantics label — 30–90 per
  rebuild on every day tap and month swipe. Never call a `DateFormat.*`
  constructor inside a cell/item builder.
