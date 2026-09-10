// CarPlayTemplateBuilder — snapshot in, CarPlay templates out.
//
// Every function here is PURE and takes `now` as a parameter, which is what
// lets RunnerTests cover the ranking, the grouping, the header subtitles and
// every omit-the-empty-field rule without a car. Never read `Date()` here.
//
// Template depth is capped at 2 on iOS 18 and the root counts, so the tab bar
// plus one detail push sits exactly at the cap — nothing below pushes again.
//
// This file is compiled only on macOS/Xcode.

import CarPlay
import UIKit

/// A job's state as the row and the detail read it. Raw-valued so the image
/// cache and the rebuild guard can key on it without a second spelling.
enum CarPlayJobState: String {
    case scheduled
    case inProgress
    case overdue
    case done
    case cancelled

    var isTerminal: Bool { self == .done || self == .cancelled }
}

/// What a row or a button does when tapped. Closures so the builder stays
/// pure; the scene delegate supplies them and MUST capture itself weakly.
struct CarPlayActions {
    var select: (SnapshotAppointment) -> Void = { _ in }
    var directions: (SnapshotAppointment) -> Void = { _ in }
    var setStatus: (SnapshotAppointment, String) -> Void = { _, _ in }
    var call: (URL) -> Void = { _ in }
    var dismissAlert: () -> Void = {}
}

/// Everything about the head unit and the viewer that the snapshot cannot say.
struct CarPlayPresentation {
    /// The car's appearance, for the dark lift. `CPTemplateApplicationScene`
    /// reports it as `contentStyle`.
    var style: UIUserInterfaceStyle = .unspecified
    /// The signed-in person's name, matched against `crew` to ring their own
    /// jobs. Nil rings nothing, which is the safe direction.
    var viewerName: String?
    /// Whether Dart is reachable. The status and Call buttons are ABSENT when
    /// it is not — never present-but-broken.
    var bridgeConnected = false
}

/// Today, ranked around the drive rather than the clock.
struct CarPlayTodayRanking {
    let inProgress: [SnapshotAppointment]
    let next: SnapshotAppointment?
    let later: [SnapshotAppointment]
    let doneCount: Int
}

enum CarPlayTemplateBuilder {
    /// Some vehicles render only 12 rows TOTAL across a list and stop, so this
    /// is one budget shared by every section of a tab, not a per-section cap —
    /// a per-section cap emits rows nobody can reach and header counts that
    /// describe them. Ordering is the real mitigation: the row that matters is
    /// first either way. Every header subtitle counts what actually fits.
    static let maxRowsPerTemplate = 12

    /// The Week tab's horizon, inherited from the snapshot window.
    static let weekLookaheadDays = 7

    // MARK: - The status ladder

    /// The stored status, normalized. The snapshot never carries `cancelled`
    /// (dropped at build time), but a stale payload might.
    static func storedState(_ appointment: SnapshotAppointment) -> CarPlayJobState {
        switch appointment.status.lowercased() {
        case "done", "completed": return .done
        case "cancelled": return .cancelled
        case "in_progress", "inprogress": return .inProgress
        default: return .scheduled
        }
    }

    /// The last day of a multi-day run, so `end` is the run's real end and not
    /// just this day's close. The counters are omitted for a single-day job,
    /// which is therefore its own last day.
    static func isLastDay(of appointment: SnapshotAppointment) -> Bool {
        (appointment.dayIndex ?? 1) >= (appointment.dayCount ?? 1)
    }

    /// Mirrors `AppointmentRecord.displayStatusAt` branch for branch, in the
    /// same order — but NOT input for input, and that difference is the gate
    /// below. The ladder compares `now` against the appointment's own
    /// `startTime`/`endTime`; `start`/`end` here are the per-day SLICE window
    /// (`slice.windowStart`/`windowEnd`), so day 1 of a three-day job is "past
    /// its end" every evening at 17:00. A window that has closed is the run's
    /// end only on the LAST day, so the two branches that mean FINISHED —
    /// `.overdue` and time off's `.done` — are reachable only there. An earlier
    /// day's closed window is still work in progress.
    static func displayState(
        _ appointment: SnapshotAppointment, now: Date
    ) -> CarPlayJobState {
        let stored = storedState(appointment)
        if stored.isTerminal { return stored }
        let ended = now > appointment.end && isLastDay(of: appointment)
        // Time off completes itself at the end of its last day.
        if appointment.isTimeOff { return ended ? .done : stored }
        // A personal block never derives in-progress or overdue — "job
        // finished?" is the wrong question for a dentist appointment.
        if appointment.personal { return stored }
        if ended { return .overdue }
        if now > appointment.start { return .inProgress }
        return stored
    }

    /// Whether the viewer is on this job's crew, which is what rings the
    /// avatar. Case-insensitive because `crew` carries the name denormalized
    /// at booking and the roster's spelling can differ.
    static func isOwnJob(
        _ appointment: SnapshotAppointment, viewerName: String?
    ) -> Bool {
        guard let viewerName, !viewerName.isEmpty else { return false }
        return (appointment.crew ?? []).contains {
            !$0.name.isEmpty
                && $0.name.caseInsensitiveCompare(viewerName) == .orderedSame
        }
    }

    // MARK: - Day selection

    static func today(in snapshot: ScheduleSnapshot?, at now: Date) -> SnapshotDay? {
        snapshot?.day(on: now)
    }

    /// The next 7 days, today excluded. Keys are `yyyy-MM-dd`, so they sort
    /// chronologically as strings and need no parsing to order.
    static func upcomingDays(
        in snapshot: ScheduleSnapshot?, from now: Date
    ) -> [SnapshotDay] {
        guard let snapshot else { return [] }
        let todayKey = ScheduleSnapshot.dayKey(now)
        return Array(
            snapshot.days
                .filter { $0.date > todayKey && !$0.appointments.isEmpty }
                .sorted { $0.date < $1.date }
                .prefix(weekLookaheadDays))
    }

    /// The inverse of `ScheduleSnapshot.dayKey`, for the Week headers.
    static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return Calendar.current.date(from: components)
    }

    // MARK: - Today ranking

    /// Now holds every job somebody has STARTED; Next is the single earliest
    /// job nobody has; Later is the rest. Terminal jobs are omitted and
    /// counted.
    static func rankToday(_ day: SnapshotDay?, now: Date) -> CarPlayTodayRanking {
        let all = day?.appointments ?? []
        let open = all
            .filter { !storedState($0).isTerminal }
            .sorted { $0.start < $1.start }
        let started = open.filter { storedState($0) == .inProgress }
        let unstarted = open.filter { storedState($0) != .inProgress }
        return CarPlayTodayRanking(
            inProgress: started,
            next: unstarted.first,
            later: Array(unstarted.dropFirst()),
            doneCount: all.count - open.count)
    }

    // MARK: - Root

    static func rootTemplate(
        snapshot: ScheduleSnapshot?,
        now: Date,
        presentation: CarPlayPresentation,
        actions: CarPlayActions
    ) -> CPTabBarTemplate {
        CPTabBarTemplate(templates: [
            todayTemplate(
                snapshot: snapshot, now: now,
                presentation: presentation, actions: actions),
            weekTemplate(
                snapshot: snapshot, now: now,
                presentation: presentation, actions: actions),
        ])
    }

    // MARK: - Today tab

    static func todayTemplate(
        snapshot: ScheduleSnapshot?,
        now: Date,
        presentation: CarPlayPresentation,
        actions: CarPlayActions
    ) -> CPListTemplate {
        let template = CPListTemplate(
            title: CarPlayStrings.todayTab,
            sections: todaySections(
                snapshot: snapshot, now: now,
                presentation: presentation, actions: actions))
        template.tabTitle = CarPlayStrings.todayTab
        template.tabImage = UIImage(systemName: "list.bullet")
        applyTodayEmptyView(to: template, snapshot: snapshot, now: now)
        return template
    }

    /// Re-ranks a template `todayTemplate` already built, IN PLACE. Installing
    /// a new root instead would put a fresh `CPTabBarTemplate` on screen every
    /// 60 s and drop the driver back to Today while they were reading Week.
    ///
    /// Returns whether the rows actually changed; most 60 s ticks change
    /// nothing, and `updateSections` is not free.
    @discardableResult
    static func refreshToday(
        _ template: CPListTemplate,
        snapshot: ScheduleSnapshot?,
        now: Date,
        presentation: CarPlayPresentation,
        actions: CarPlayActions
    ) -> Bool {
        let sections = todaySections(
            snapshot: snapshot, now: now,
            presentation: presentation, actions: actions)
        let changed = renderKey(sections) != renderKey(template.sections)
        if changed { template.updateSections(sections) }
        // Always re-applied: it is two string assignments, and its subtitle
        // names the next job, which moves without any section changing.
        applyTodayEmptyView(to: template, snapshot: snapshot, now: now)
        return changed
    }

    /// Now / Next / Later today, each present only when it holds a row. Rows
    /// are drawn from one shared budget in that order, so the section that
    /// matters least is the one that loses rows.
    static func todaySections(
        snapshot: ScheduleSnapshot?,
        now: Date,
        presentation: CarPlayPresentation,
        actions: CarPlayActions
    ) -> [CPListSection] {
        let ranking = rankToday(today(in: snapshot, at: now), now: now)
        var budget = maxRowsPerTemplate
        var sections: [CPListSection] = []

        let started = fit(ranking.inProgress, into: &budget)
        if !started.isEmpty {
            let subtitle = started.count == 1
                ? CarPlayStrings.startedAt(started[0].start)
                : CarPlayStrings.onSite(started.count)
            sections.append(
                section(
                    header: CarPlayStrings.nowSection,
                    subtitle: subtitle,
                    appointments: started,
                    snapshot: snapshot, now: now,
                    presentation: presentation, actions: actions))
        }

        let upNext = fit(ranking.next.map { [$0] } ?? [], into: &budget)
        if let next = upNext.first {
            sections.append(
                section(
                    header: CarPlayStrings.nextSection,
                    subtitle: CarPlayStrings.countdown(
                        start: next.start, end: next.end, now: now),
                    appointments: upNext,
                    snapshot: snapshot, now: now,
                    presentation: presentation, actions: actions))
        }

        let later = fit(ranking.later, into: &budget)
        if !later.isEmpty {
            sections.append(
                section(
                    header: CarPlayStrings.laterSection,
                    subtitle: CarPlayStrings.laterSubtitle(
                        more: later.count, done: ranking.doneCount),
                    appointments: later,
                    snapshot: snapshot, now: now,
                    presentation: presentation, actions: actions))
        }

        return sections
    }

    /// Takes what [budget] still allows and spends it. The header that names
    /// the result counts what comes back, never what was offered.
    private static func fit(
        _ appointments: [SnapshotAppointment], into budget: inout Int
    ) -> [SnapshotAppointment] {
        let taken = Array(appointments.prefix(max(budget, 0)))
        budget -= taken.count
        return taken
    }

    // MARK: - Week tab

    static func weekTemplate(
        snapshot: ScheduleSnapshot?,
        now: Date,
        presentation: CarPlayPresentation,
        actions: CarPlayActions
    ) -> CPListTemplate {
        let template = CPListTemplate(
            title: CarPlayStrings.weekTab,
            sections: weekSections(
                snapshot: snapshot, now: now,
                presentation: presentation, actions: actions))
        template.tabTitle = CarPlayStrings.weekTab
        template.tabImage = UIImage(systemName: "calendar")
        applyWeekEmptyView(to: template, snapshot: snapshot)
        return template
    }

    /// The Week twin of `refreshToday`, and it earns its keep for the same
    /// reason: a day rolls over and a job's state moves without any write.
    @discardableResult
    static func refreshWeek(
        _ template: CPListTemplate,
        snapshot: ScheduleSnapshot?,
        now: Date,
        presentation: CarPlayPresentation,
        actions: CarPlayActions
    ) -> Bool {
        let sections = weekSections(
            snapshot: snapshot, now: now,
            presentation: presentation, actions: actions)
        let changed = renderKey(sections) != renderKey(template.sections)
        if changed { template.updateSections(sections) }
        applyWeekEmptyView(to: template, snapshot: snapshot)
        return changed
    }

    /// One section per upcoming day, today excluded. Terminal jobs are dropped
    /// the same way Today drops them — a job already done on Friday is not
    /// something the driver is being sent to — and a day left with no open job
    /// is absent rather than empty.
    static func weekSections(
        snapshot: ScheduleSnapshot?,
        now: Date,
        presentation: CarPlayPresentation,
        actions: CarPlayActions
    ) -> [CPListSection] {
        var budget = maxRowsPerTemplate
        var sections: [CPListSection] = []
        for day in upcomingDays(in: snapshot, from: now) {
            let open = day.appointments
                .filter { !storedState($0).isTerminal }
                .sorted { $0.start < $1.start }
            let drawn = fit(open, into: &budget)
            if drawn.isEmpty { continue }
            let date = CarPlayTemplateBuilder.date(fromDayKey: day.date)
            let isTomorrow = date.map(Calendar.current.isDateInTomorrow) ?? false
            let header = isTomorrow
                ? CarPlayStrings.tomorrowSection
                : date.map(CarPlayStrings.weekday) ?? day.date
            let subtitle = date.map {
                CarPlayStrings.daySubtitle(
                    $0, count: drawn.count, includeWeekday: isTomorrow)
            }
            sections.append(
                section(
                    header: header,
                    subtitle: subtitle,
                    appointments: drawn,
                    snapshot: snapshot, now: now,
                    presentation: presentation, actions: actions))
        }
        return sections
    }

    // MARK: - Detail

    /// When / Where / Job / Crew (admin only) / Status, in that order, empty
    /// rows omitted. At most three actions, which is the template's cap.
    static func detailTemplate(
        for appointment: SnapshotAppointment,
        snapshot: ScheduleSnapshot?,
        now: Date,
        presentation: CarPlayPresentation,
        dialableURI: URL?,
        actions: CarPlayActions
    ) -> CPInformationTemplate {
        let address = appointment.address.trimmingCharacters(in: .whitespaces)
        let title = (appointment.title ?? "")
            .trimmingCharacters(in: .whitespaces)
        let crew = appointment.crew ?? []

        var items: [CPInformationItem] = [
            CPInformationItem(
                title: CarPlayStrings.whenLabel,
                detail: CarPlayStrings.whenValue(appointment, now: now)),
        ]
        if !address.isEmpty {
            items.append(
                CPInformationItem(
                    title: CarPlayStrings.whereLabel, detail: address))
        }
        if !title.isEmpty {
            items.append(
                CPInformationItem(
                    title: CarPlayStrings.jobLabel, detail: title))
        }
        if snapshot?.isAdmin == true, !crew.isEmpty {
            items.append(
                CPInformationItem(
                    title: CarPlayStrings.crewLabel,
                    detail: CarPlayStrings.crewValue(crew)))
        }
        items.append(
            CPInformationItem(
                title: CarPlayStrings.statusLabel,
                detail: CarPlayStrings.stateWord(
                    displayState(appointment, now: now))))

        var buttons: [CPTextButton] = []
        if !address.isEmpty {
            buttons.append(
                CPTextButton(
                    title: CarPlayStrings.directions,
                    textStyle: .confirm
                ) { _ in actions.directions(appointment) })
        }
        // The BUTTON keys off the stored status, not the display ladder —
        // `overdue` is display-only and has no stored value to write.
        if presentation.bridgeConnected {
            switch storedState(appointment) {
            case .scheduled:
                buttons.append(
                    CPTextButton(
                        title: CarPlayStrings.startJob, textStyle: .normal
                    ) { _ in actions.setStatus(appointment, "in_progress") })
            case .inProgress:
                buttons.append(
                    CPTextButton(
                        title: CarPlayStrings.markComplete, textStyle: .normal
                    ) { _ in actions.setStatus(appointment, "done") })
            case .overdue, .done, .cancelled:
                break
            }
        }
        if presentation.bridgeConnected, let dialableURI {
            buttons.append(
                CPTextButton(
                    title: CarPlayStrings.call, textStyle: .normal
                ) { _ in actions.call(dialableURI) })
        }

        return CPInformationTemplate(
            title: CarPlayStrings.who(appointment),
            layout: .leading,
            items: items,
            actions: buttons)
    }

    // MARK: - Mark-complete hand-off

    /// Named the next job, because the completed one leaves the list the
    /// moment it is written. Modal, so it costs no template depth.
    static func handoffAlert(
        after completed: SnapshotAppointment,
        snapshot: ScheduleSnapshot?,
        now: Date,
        actions: CarPlayActions
    ) -> CPAlertTemplate {
        let ranking = rankToday(today(in: snapshot, at: now), now: now)
        // The job to DRIVE to next: the earliest nobody has started, then the
        // rest of the day, and only then something already under way.
        let upcoming = [ranking.next].compactMap { $0 } + ranking.later
            + ranking.inProgress
        let next = upcoming.first { $0.id != completed.id }
        let headline = CarPlayStrings.completedTitle(completed)

        let variants: [String]
        var alertActions: [CPAlertAction] = []
        if let next {
            let line = CarPlayStrings.nextJobLine(next)
            variants = ["\(headline). \(line)", line]
            if !next.address.trimmingCharacters(in: .whitespaces).isEmpty {
                alertActions.append(
                    CPAlertAction(
                        title: CarPlayStrings.directions, style: .default
                    ) { _ in actions.directions(next) })
            }
        } else {
            variants = [
                "\(headline). \(CarPlayStrings.noMoreJobsToday)", headline,
            ]
        }
        alertActions.append(
            CPAlertAction(title: CarPlayStrings.done, style: .cancel) { _ in
                actions.dismissAlert()
            })
        return CPAlertTemplate(titleVariants: variants, actions: alertActions)
    }

    // MARK: - Rows

    static func row(
        for appointment: SnapshotAppointment,
        snapshot: ScheduleSnapshot?,
        now: Date,
        presentation: CarPlayPresentation,
        actions: CarPlayActions
    ) -> CPListItem {
        let isAdmin = snapshot?.isAdmin == true
        let state = displayState(appointment, now: now)
        let accessory = CarPlayImages.stateAccessory(
            state, style: presentation.style)
        let item = CPListItem(
            text: isAdmin
                ? CarPlayStrings.adminRowTitle(appointment)
                : CarPlayStrings.who(appointment),
            detailText: CarPlayStrings.detailLine(appointment),
            image: rowImage(
                appointment, isAdmin: isAdmin, state: state,
                presentation: presentation),
            accessoryImage: accessory,
            accessoryType: accessory == nil
                ? .disclosureIndicator : CPListItemAccessoryType.none)
        item.userInfo = rowKey(
            appointment, isAdmin: isAdmin, state: state,
            presentation: presentation)
        item.handler = { _, completion in
            actions.select(appointment)
            completion()
        }
        return item
    }

    /// Everything a row DRAWS that its two strings do not say — the tile's
    /// time, the avatar's crew and ring, the state both are tinted by.
    private static func rowKey(
        _ appointment: SnapshotAppointment,
        isAdmin: Bool,
        state: CarPlayJobState,
        presentation: CarPlayPresentation
    ) -> String {
        var parts = [
            appointment.id,
            state.rawValue,
            String(appointment.startMillis),
            appointment.allDay ? "1" : "0",
        ]
        guard isAdmin else { return parts.joined(separator: "|") }
        parts.append(
            (appointment.crew ?? [])
                .map { "\($0.name):\($0.storedColor)" }
                .joined(separator: ","))
        parts.append(
            isOwnJob(appointment, viewerName: presentation.viewerName)
                ? "1" : "0")
        return parts.joined(separator: "|")
    }

    /// What a tab currently draws, as text. Two builds that agree on this draw
    /// the same thing, so the refreshes above skip `updateSections`, which
    /// re-renders every image and can drop the driver's place in the list.
    static func renderKey(_ sections: [CPListSection]) -> String {
        sections.map { section -> String in
            let drawn: [String] = section.items.map { item -> String in
                guard let row = item as? CPListItem else { return "" }
                return [
                    row.userInfo as? String ?? "",
                    row.text ?? "",
                    row.detailText ?? "",
                ].joined(separator: "\u{1F}")
            }
            return ([section.header ?? "", section.headerSubtitle ?? ""] + drawn)
                .joined(separator: "\u{1E}")
        }.joined(separator: "\u{1D}")
    }

    private static func rowImage(
        _ appointment: SnapshotAppointment,
        isAdmin: Bool,
        state: CarPlayJobState,
        presentation: CarPlayPresentation
    ) -> UIImage? {
        guard isAdmin else {
            return CarPlayImages.timeTile(
                appointment.allDay
                    ? CarPlayStrings.allDayTile
                    : CarPlayStrings.time(appointment.start),
                state: state,
                style: presentation.style)
        }
        return CarPlayImages.crewAvatar(
            crew: appointment.crew ?? [],
            isOwn: isOwnJob(appointment, viewerName: presentation.viewerName),
            style: presentation.style)
    }

    private static func section(
        header: String,
        subtitle: String?,
        appointments: [SnapshotAppointment],
        snapshot: ScheduleSnapshot?,
        now: Date,
        presentation: CarPlayPresentation,
        actions: CarPlayActions
    ) -> CPListSection {
        // Already cut to the template's shared budget by `fit`.
        let items = appointments.map {
            row(
                for: $0, snapshot: snapshot, now: now,
                presentation: presentation, actions: actions)
        }
        return CPListSection(
            items: items,
            header: header,
            headerSubtitle: subtitle,
            headerImage: nil,
            headerButton: nil,
            sectionIndexTitle: nil)
    }

    // MARK: - Empty views

    /// Re-applied on every refresh, not just at install: the Today subtitle
    /// names the next job, which moves with the clock like the ranking above.
    private static func applyTodayEmptyView(
        to template: CPListTemplate, snapshot: ScheduleSnapshot?, now: Date
    ) {
        applyEmptyView(
            to: template,
            title: CarPlayStrings.todayEmptyTitle,
            subtitles: todayEmptySubtitles(snapshot: snapshot, now: now),
            snapshot: snapshot)
    }

    private static func applyWeekEmptyView(
        to template: CPListTemplate, snapshot: ScheduleSnapshot?
    ) {
        applyEmptyView(
            to: template,
            title: CarPlayStrings.weekEmptyTitle,
            subtitles: [CarPlayStrings.weekEmptySubtitle],
            snapshot: snapshot)
    }

    private static func applyEmptyView(
        to template: CPListTemplate,
        title: String,
        subtitles: [String],
        snapshot: ScheduleSnapshot?
    ) {
        guard snapshot != nil else {
            template.emptyViewTitleVariants = [CarPlayStrings.signedOutTitle]
            template.emptyViewSubtitleVariants = [
                CarPlayStrings.signedOutSubtitle,
            ]
            return
        }
        template.emptyViewTitleVariants = [title]
        template.emptyViewSubtitleVariants = subtitles
    }

    private static func todayEmptySubtitles(
        snapshot: ScheduleSnapshot?, now: Date
    ) -> [String] {
        guard let next = snapshot?.nextAppointment(after: now) else {
            return [CarPlayStrings.nothingAheadSubtitle]
        }
        return [CarPlayStrings.todayEmptyNext(next)]
    }
}
