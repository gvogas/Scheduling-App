// CarPlayTemplateBuilderTests — the builder is pure and takes `now`, so the
// ranking, the grouping, the header subtitles and every omit-the-empty-field
// rule are provable without a car.
//
// Fixed clock: Thursday 10 September 2026, 10:12 local. Tomorrow is therefore
// Friday 11 September, which is the day the plan's mockups name.

import CarPlay
import XCTest

@testable import Runner

final class CarPlayTemplateBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private let now = CarPlayTemplateBuilderTests.fixedDate(
        day: 10, hour: 10, minute: 12)

    private static func fixedDate(
        day: Int, hour: Int, minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        Self.fixedDate(day: day, hour: hour, minute: minute)
    }

    private func job(
        id: String,
        day: Int = 10,
        from: (Int, Int),
        to: (Int, Int),
        status: String = "pending",
        client: String = "Tremblay",
        title: String? = nil,
        address: String = "142 Rue Principale",
        allDay: Bool = false,
        personal: Bool = false,
        dayOff: Bool = false,
        dayIndex: Int? = nil,
        dayCount: Int? = nil,
        crew: [SnapshotCrewMember]? = nil
    ) -> SnapshotAppointment {
        // `from`/`to` are THIS day's slice window, which is what the Dart
        // builder writes — not the whole run's start and end.
        let start = at(day: day, hour: from.0, minute: from.1)
        let end = at(day: day, hour: to.0, minute: to.1)
        return SnapshotAppointment(
            id: id,
            startMillis: start.timeIntervalSince1970 * 1000,
            endMillis: end.timeIntervalSince1970 * 1000,
            clientName: client,
            title: title,
            address: address,
            status: status,
            isAllDay: allDay,
            // nil rather than false, mirroring the builder: the key is
            // OMITTED when false, never written as `false`.
            isPersonal: personal ? true : nil,
            isDayOff: dayOff ? true : nil,
            dayIndex: dayIndex,
            dayCount: dayCount,
            isOvernight: nil,
            crew: crew)
    }

    private func day(_ dayOfMonth: Int, _ jobs: [SnapshotAppointment]) -> SnapshotDay {
        SnapshotDay(
            date: ScheduleSnapshot.dayKey(at(day: dayOfMonth, hour: 12)),
            appointments: jobs)
    }

    private func snapshot(
        role: String = "employee",
        viewer: String? = nil,
        days: [SnapshotDay]
    ) -> ScheduleSnapshot {
        ScheduleSnapshot(
            version: 4, generatedAt: 0, role: role, viewer: viewer, days: days)
    }

    private func rows(_ section: CPListSection) -> [CPListItem] {
        section.items.compactMap { $0 as? CPListItem }
    }

    /// A section's shape as comparable text — `CPListSection` is an NSObject
    /// with no value equality to assert against.
    private func describe(_ sections: [CPListSection]) -> [String] {
        sections.map { section in
            [
                section.header ?? "",
                section.headerSubtitle ?? "",
                rows(section).map { $0.text ?? "" }.joined(separator: "|"),
            ].joined(separator: " / ")
        }
    }

    // MARK: - Today ranking

    func testNowHoldsEveryInProgressJob() {
        let ranking = CarPlayTemplateBuilder.rankToday(
            day(10, [
                job(id: "a", from: (8, 0), to: (9, 0), status: "in_progress"),
                job(id: "b", from: (10, 0), to: (11, 0), status: "in_progress"),
                job(id: "c", from: (13, 30), to: (14, 30)),
            ]),
            now: now)

        XCTAssertEqual(ranking.inProgress.map(\.id), ["a", "b"])
        XCTAssertEqual(ranking.next?.id, "c")
        XCTAssertTrue(ranking.later.isEmpty)
    }

    func testNextIsExactlyOneAndIsTheOverdueJob() {
        let ranking = CarPlayTemplateBuilder.rankToday(
            day(10, [
                job(id: "late", from: (9, 15), to: (9, 15)),
                job(id: "soon", from: (10, 30), to: (11, 30)),
                job(id: "last", from: (16, 30), to: (17, 30)),
            ]),
            now: now)

        XCTAssertEqual(ranking.next?.id, "late")
        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(ranking.next!, now: now),
            .overdue)
        XCTAssertEqual(ranking.later.map(\.id), ["soon", "last"])
    }

    func testTerminalJobsAreOmittedAndCounted() {
        let ranking = CarPlayTemplateBuilder.rankToday(
            day(10, [
                job(id: "done", from: (8, 0), to: (9, 0), status: "done"),
                job(id: "gone", from: (8, 30), to: (9, 30), status: "cancelled"),
                job(id: "open", from: (13, 30), to: (14, 30)),
            ]),
            now: now)

        XCTAssertEqual(ranking.inProgress.count, 0)
        XCTAssertEqual(ranking.next?.id, "open")
        XCTAssertEqual(ranking.doneCount, 2)
    }

    func testEmptySectionsAreAbsent() {
        let template = CarPlayTemplateBuilder.todayTemplate(
            snapshot: snapshot(days: [
                day(10, [job(id: "a", from: (13, 30), to: (14, 30))]),
            ]),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())

        XCTAssertEqual(template.sections.count, 1)
        XCTAssertEqual(template.sections[0].header, CarPlayStrings.nextSection)
    }

    // MARK: - Header subtitles

    func testTodayHeaderSubtitles() throws {
        try XCTSkipIf(CarPlayStrings.french, "English phrasing under test")
        let template = CarPlayTemplateBuilder.todayTemplate(
            snapshot: snapshot(days: [
                day(10, [
                    job(id: "on", from: (10, 0), to: (12, 0), status: "in_progress"),
                    job(id: "late", from: (9, 15), to: (9, 15)),
                    job(id: "l1", from: (13, 30), to: (14, 30)),
                    job(id: "l2", from: (16, 30), to: (17, 30)),
                    job(id: "d", from: (8, 0), to: (9, 0), status: "done"),
                ]),
            ]),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())

        XCTAssertEqual(
            template.sections.map(\.headerSubtitle),
            ["Started 10:00", "Overdue by 57 min", "2 more jobs · 1 done"])
    }

    func testNextSubtitleCountsDownToAFutureJob() throws {
        try XCTSkipIf(CarPlayStrings.french, "English phrasing under test")
        let template = CarPlayTemplateBuilder.todayTemplate(
            snapshot: snapshot(days: [
                day(10, [job(id: "a", from: (10, 30), to: (11, 30))]),
            ]),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())

        XCTAssertEqual(template.sections[0].headerSubtitle, "Starts in 18 min")
    }

    func testTwoOnSiteCollapsesTheNowSubtitle() throws {
        try XCTSkipIf(CarPlayStrings.french, "English phrasing under test")
        let template = CarPlayTemplateBuilder.todayTemplate(
            snapshot: snapshot(role: "admin", days: [
                day(10, [
                    job(id: "a", from: (9, 0), to: (12, 0), status: "in_progress"),
                    job(id: "b", from: (9, 30), to: (12, 0), status: "in_progress"),
                ]),
            ]),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())

        XCTAssertEqual(template.sections[0].headerSubtitle, "2 on site")
    }

    // MARK: - Week tab

    func testWeekGroupsByDayInOrderAndExcludesToday() throws {
        try XCTSkipIf(CarPlayStrings.french, "English phrasing under test")
        let template = CarPlayTemplateBuilder.weekTemplate(
            snapshot: snapshot(days: [
                day(10, [job(id: "today", from: (13, 0), to: (14, 0))]),
                day(14, [
                    job(id: "mon1", day: 14, from: (8, 0), to: (9, 0)),
                    job(id: "mon2", day: 14, from: (11, 0), to: (12, 0)),
                ]),
                day(11, [job(id: "fri", day: 11, from: (13, 0), to: (14, 0))]),
                day(12, []),
            ]),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())

        XCTAssertEqual(template.sections.map(\.header), ["Tomorrow", "Monday"])
        XCTAssertEqual(
            template.sections.map(\.headerSubtitle),
            ["Friday 11 September · 1 job", "14 September · 2 jobs"])
        XCTAssertEqual(rows(template.sections[1]).count, 2)
    }

    func testWeekDropsTerminalJobsAndTheDaysLeftWithNone() {
        let template = CarPlayTemplateBuilder.weekTemplate(
            snapshot: snapshot(days: [
                day(11, [
                    job(id: "open", day: 11, from: (9, 0), to: (10, 0)),
                    job(
                        id: "closed", day: 11, from: (11, 0), to: (12, 0),
                        status: "done", client: "Pelletier"),
                ]),
                day(12, [
                    job(
                        id: "gone", day: 12, from: (9, 0), to: (10, 0),
                        status: "cancelled"),
                ]),
            ]),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())

        XCTAssertEqual(template.sections.count, 1)
        XCTAssertEqual(rows(template.sections[0]).map(\.text), ["Tremblay"])
        XCTAssertTrue(
            template.sections[0].headerSubtitle?
                .hasSuffix(CarPlayStrings.jobCount(1)) == true)
    }

    // MARK: - The row budget

    func testTodaySpendsOneBudgetAcrossItsSectionsAndCountsWhatItDrew() {
        var jobs = [
            job(id: "on1", from: (9, 0), to: (12, 0), status: "in_progress"),
            job(id: "on2", from: (9, 30), to: (12, 0), status: "in_progress"),
        ]
        for minute in 0...20 {
            jobs.append(job(id: "l\(minute)", from: (13, minute), to: (14, 0)))
        }

        let sections = CarPlayTemplateBuilder.todaySections(
            snapshot: snapshot(days: [day(10, jobs)]),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())

        let drawn = sections.map { rows($0).count }
        XCTAssertEqual(drawn, [2, 1, 9])
        XCTAssertEqual(
            drawn.reduce(0, +), CarPlayTemplateBuilder.maxRowsPerTemplate)
        // The header may never claim more jobs than the rows below it.
        XCTAssertEqual(
            sections[2].headerSubtitle,
            CarPlayStrings.laterSubtitle(more: 9, done: 0))
    }

    func testWeekSpendsTheSameBudgetAndItsDayCountsMatchItsRows() {
        let five: (Int) -> [SnapshotAppointment] = { dayOfMonth in
            (0...4).map { index in
                self.job(
                    id: "d\(dayOfMonth)-\(index)", day: dayOfMonth,
                    from: (9 + index, 0), to: (9 + index, 30))
            }
        }
        let sections = CarPlayTemplateBuilder.weekSections(
            snapshot: snapshot(days: [
                day(11, five(11)), day(12, five(12)), day(13, five(13)),
                day(14, five(14)),
            ]),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())

        XCTAssertEqual(sections.map { rows($0).count }, [5, 5, 2])
        XCTAssertEqual(
            sections.map { rows($0).count }.reduce(0, +),
            CarPlayTemplateBuilder.maxRowsPerTemplate)
        XCTAssertTrue(
            sections[2].headerSubtitle?
                .hasSuffix(CarPlayStrings.jobCount(2)) == true)
    }

    // MARK: - Rows

    func testAdminRowLeadsWithTheTimeAndTechnicianRowDoesNot() {
        let assigned = job(
            id: "a", from: (8, 0), to: (9, 0),
            crew: [SnapshotCrewMember(name: "Luc Bergeron", colorValue: 0xFF00_5CC8)])

        let adminRow = CarPlayTemplateBuilder.row(
            for: assigned,
            snapshot: snapshot(role: "admin", days: []),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())
        let technicianRow = CarPlayTemplateBuilder.row(
            for: assigned,
            snapshot: snapshot(days: []),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())

        XCTAssertEqual(adminRow.text, "\(CarPlayStrings.time(assigned.start))  Tremblay")
        XCTAssertEqual(technicianRow.text, "Tremblay")
        XCTAssertEqual(adminRow.image?.size, CarPlayImages.slotSize)
        XCTAssertEqual(technicianRow.image?.size, CarPlayImages.slotSize)
    }

    func testAdminRowHasNoImageWithoutCrew() {
        let row = CarPlayTemplateBuilder.row(
            for: job(id: "a", from: (8, 0), to: (9, 0)),
            snapshot: snapshot(role: "admin", days: []),
            now: now,
            presentation: CarPlayPresentation(),
            actions: CarPlayActions())

        XCTAssertNil(row.image)
    }

    func testRowTitleFallsBackFromClientToTitleToGenericLabel() {
        let named = CarPlayStrings.who(job(id: "a", from: (8, 0), to: (9, 0)))
        let titled = CarPlayStrings.who(
            job(id: "b", from: (8, 0), to: (9, 0), client: "", title: "Rendez-vous"))
        let bare = CarPlayStrings.who(
            job(id: "c", from: (8, 0), to: (9, 0), client: "", title: "  "))

        XCTAssertEqual(named, "Tremblay")
        XCTAssertEqual(titled, "Rendez-vous")
        // The exact generic label, not merely "something non-empty" — that
        // assertion passed for any string, including a blank row heading.
        XCTAssertEqual(
            bare, CarPlayStrings.french ? "Client sans nom" : "Unnamed client")
    }

    func testAWhitespaceOnlyClientNameIsNotAName() {
        let blank = job(
            id: "a", from: (8, 0), to: (9, 0), client: "   ",
            title: "Rendez-vous")
        let blankAndUntitled = job(
            id: "b", from: (8, 0), to: (9, 0), client: " ", title: nil)

        XCTAssertEqual(CarPlayStrings.who(blank), "Rendez-vous")
        XCTAssertEqual(
            CarPlayStrings.who(blankAndUntitled),
            CarPlayStrings.french ? "Client sans nom" : "Unnamed client")
        // The title named the row, so line two must not repeat it.
        XCTAssertEqual(CarPlayStrings.detailLine(blank), "142 Rue Principale")
    }

    func testLineTwoPutsTheTitleBeforeTheAddress() {
        let both = CarPlayStrings.detailLine(
            job(id: "a", from: (8, 0), to: (9, 0), title: "Réparation de fuite"))
        let addressOnly = CarPlayStrings.detailLine(
            job(id: "b", from: (8, 0), to: (9, 0)))

        XCTAssertEqual(both, "Réparation de fuite · 142 Rue Principale")
        XCTAssertEqual(addressOnly, "142 Rue Principale")
    }

    // MARK: - Detail

    func testDetailOmitsWhereAndDirectionsWithoutAnAddress() {
        let template = CarPlayTemplateBuilder.detailTemplate(
            for: job(id: "a", from: (8, 0), to: (9, 0), address: ""),
            snapshot: snapshot(days: []),
            now: now,
            presentation: CarPlayPresentation(bridgeConnected: true),
            dialableURI: nil,
            actions: CarPlayActions())

        XCTAssertFalse(
            template.items.contains { $0.title == CarPlayStrings.whereLabel })
        XCTAssertFalse(
            template.actions.contains { $0.title == CarPlayStrings.directions })
    }

    func testDetailRowOrderAndCrewIsAdminOnly() {
        let assigned = job(
            id: "a", from: (8, 0), to: (9, 0), title: "Réparation de fuite",
            crew: [SnapshotCrewMember(name: "Luc Bergeron", colorValue: 0xFF00_5CC8)])

        let adminItems = CarPlayTemplateBuilder.detailTemplate(
            for: assigned,
            snapshot: snapshot(role: "admin", days: []),
            now: now,
            presentation: CarPlayPresentation(),
            dialableURI: nil,
            actions: CarPlayActions()
        ).items.compactMap(\.title)

        let technicianItems = CarPlayTemplateBuilder.detailTemplate(
            for: assigned,
            snapshot: snapshot(days: []),
            now: now,
            presentation: CarPlayPresentation(),
            dialableURI: nil,
            actions: CarPlayActions()
        ).items.compactMap(\.title)

        XCTAssertEqual(
            adminItems,
            [
                CarPlayStrings.whenLabel, CarPlayStrings.whereLabel,
                CarPlayStrings.jobLabel, CarPlayStrings.crewLabel,
                CarPlayStrings.statusLabel,
            ])
        XCTAssertFalse(technicianItems.contains(CarPlayStrings.crewLabel))
    }

    func testStatusRowReadsTheLadderWhileTheButtonReadsTheStoredStatus() {
        let late = job(id: "a", from: (9, 15), to: (9, 15))
        let template = CarPlayTemplateBuilder.detailTemplate(
            for: late,
            snapshot: snapshot(days: []),
            now: now,
            presentation: CarPlayPresentation(bridgeConnected: true),
            dialableURI: nil,
            actions: CarPlayActions())

        let status = template.items.first {
            $0.title == CarPlayStrings.statusLabel
        }
        XCTAssertEqual(status?.detail, CarPlayStrings.stateWord(.overdue))
        XCTAssertTrue(
            template.actions.contains { $0.title == CarPlayStrings.startJob })
    }

    func testTheStatusButtonIsTheNextStepOnly() {
        let started = job(id: "a", from: (9, 0), to: (12, 0), status: "in_progress")
        let closed = job(id: "b", from: (8, 0), to: (9, 0), status: "done")
        let connected = CarPlayPresentation(bridgeConnected: true)

        let startedTitles = CarPlayTemplateBuilder.detailTemplate(
            for: started, snapshot: snapshot(days: []), now: now,
            presentation: connected, dialableURI: nil,
            actions: CarPlayActions()
        ).actions.compactMap(\.title)

        let closedTitles = CarPlayTemplateBuilder.detailTemplate(
            for: closed, snapshot: snapshot(days: []), now: now,
            presentation: connected, dialableURI: nil,
            actions: CarPlayActions()
        ).actions.compactMap(\.title)

        XCTAssertEqual(
            startedTitles,
            [CarPlayStrings.directions, CarPlayStrings.markComplete])
        XCTAssertEqual(closedTitles, [CarPlayStrings.directions])
    }

    func testEngineDependentButtonsAreAbsentWhenTheBridgeIsDown() {
        let appointment = job(id: "a", from: (13, 30), to: (14, 30))
        let dial = URL(string: "tel:5145551234")!

        let connected = CarPlayTemplateBuilder.detailTemplate(
            for: appointment, snapshot: snapshot(days: []), now: now,
            presentation: CarPlayPresentation(bridgeConnected: true),
            dialableURI: dial, actions: CarPlayActions()
        ).actions.compactMap(\.title)

        let offline = CarPlayTemplateBuilder.detailTemplate(
            for: appointment, snapshot: snapshot(days: []), now: now,
            presentation: CarPlayPresentation(bridgeConnected: false),
            dialableURI: dial, actions: CarPlayActions()
        ).actions.compactMap(\.title)

        XCTAssertEqual(
            connected,
            [
                CarPlayStrings.directions, CarPlayStrings.startJob,
                CarPlayStrings.call,
            ])
        XCTAssertEqual(offline, [CarPlayStrings.directions])
        XCTAssertLessThanOrEqual(connected.count, 3)
    }

    func testCallIsAbsentWithoutADialableNumber() {
        let titles = CarPlayTemplateBuilder.detailTemplate(
            for: job(id: "a", from: (13, 30), to: (14, 30)),
            snapshot: snapshot(days: []), now: now,
            presentation: CarPlayPresentation(bridgeConnected: true),
            dialableURI: nil, actions: CarPlayActions()
        ).actions.compactMap(\.title)

        XCTAssertFalse(titles.contains(CarPlayStrings.call))
    }

    // MARK: - Empty and signed-out views

    func testEmptyTodayAndWeekUseTheTemplateEmptyView() {
        let empty = snapshot(days: [day(10, []), day(11, [])])

        let today = CarPlayTemplateBuilder.todayTemplate(
            snapshot: empty, now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())
        let week = CarPlayTemplateBuilder.weekTemplate(
            snapshot: empty, now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())

        XCTAssertTrue(today.sections.isEmpty)
        XCTAssertEqual(
            today.emptyViewTitleVariants, [CarPlayStrings.todayEmptyTitle])
        XCTAssertTrue(week.sections.isEmpty)
        XCTAssertEqual(
            week.emptyViewTitleVariants, [CarPlayStrings.weekEmptyTitle])
    }

    func testEmptyTodayNamesTheNextJobInTheWindow() throws {
        try XCTSkipIf(CarPlayStrings.french, "English phrasing under test")
        let template = CarPlayTemplateBuilder.todayTemplate(
            snapshot: snapshot(days: [
                day(10, []),
                day(14, [
                    job(id: "mon", day: 14, from: (8, 0), to: (9, 0),
                        client: "Lachance"),
                ]),
            ]),
            now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())

        XCTAssertEqual(
            template.emptyViewSubtitleVariants, ["Next: Monday 14 September 8:00, Lachance"])
    }

    func testSignedOutShowsTheSameMessageOnBothTabs() {
        let today = CarPlayTemplateBuilder.todayTemplate(
            snapshot: nil, now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())
        let week = CarPlayTemplateBuilder.weekTemplate(
            snapshot: nil, now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())

        XCTAssertEqual(
            today.emptyViewTitleVariants, [CarPlayStrings.signedOutTitle])
        XCTAssertEqual(
            week.emptyViewSubtitleVariants, [CarPlayStrings.signedOutSubtitle])
    }

    // MARK: - Root

    func testRootIsATwoTabBarWithTodayFirst() {
        let root = CarPlayTemplateBuilder.rootTemplate(
            snapshot: snapshot(days: []), now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())

        XCTAssertEqual(root.templates.count, 2)
        XCTAssertEqual(root.templates.first?.tabTitle, CarPlayStrings.todayTab)
        XCTAssertEqual(root.templates.last?.tabTitle, CarPlayStrings.weekTab)
    }

    // MARK: - Mark-complete hand-off

    func testHandoffAlertNamesTheNextJobAndOffersDirections() {
        let completed = job(id: "a", from: (9, 0), to: (10, 0), status: "in_progress")
        let alert = CarPlayTemplateBuilder.handoffAlert(
            after: completed,
            snapshot: snapshot(days: [
                day(10, [
                    completed,
                    job(id: "b", from: (13, 30), to: (14, 30),
                        client: "Pelletier", address: "1290 Rue Saint-Jean"),
                ]),
            ]),
            now: now,
            actions: CarPlayActions())

        XCTAssertTrue(alert.titleVariants[0].contains("Pelletier"))
        XCTAssertEqual(
            alert.actions.map(\.title),
            [CarPlayStrings.directions, CarPlayStrings.done])
    }

    func testHandoffAlertWithNoNextJobOffersOnlyDone() {
        let completed = job(id: "a", from: (9, 0), to: (10, 0), status: "in_progress")
        let alert = CarPlayTemplateBuilder.handoffAlert(
            after: completed,
            snapshot: snapshot(days: [day(10, [completed])]),
            now: now,
            actions: CarPlayActions())

        XCTAssertEqual(alert.actions.map(\.title), [CarPlayStrings.done])
    }

    func testHandoffAlertOmitsDirectionsForAnAddresslessNextJob() {
        let completed = job(id: "a", from: (9, 0), to: (10, 0), status: "in_progress")
        let alert = CarPlayTemplateBuilder.handoffAlert(
            after: completed,
            snapshot: snapshot(days: [
                day(10, [
                    completed,
                    job(id: "b", from: (13, 30), to: (14, 30), address: ""),
                ]),
            ]),
            now: now,
            actions: CarPlayActions())

        XCTAssertEqual(alert.actions.map(\.title), [CarPlayStrings.done])
    }

    // MARK: - The status ladder

    func testAPersonalBlockNeverDerivesOverdueOrInProgress() {
        let ended = job(id: "a", from: (9, 0), to: (9, 15), personal: true)
        let running = job(id: "b", from: (10, 0), to: (11, 0), personal: true)

        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(ended, now: now), .scheduled)
        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(running, now: now), .scheduled)
    }

    func testADayOffCompletesItselfAtTheEndOfItsLastDay() {
        let ended = job(
            id: "a", from: (0, 0), to: (9, 15), personal: true, dayOff: true)
        let running = job(
            id: "b", from: (0, 0), to: (23, 59), personal: true, dayOff: true)
        // The flag is meaningful only through isTimeOff — a client visit
        // carrying a stray one must not complete itself.
        let strayFlag = job(id: "c", from: (9, 0), to: (9, 15), dayOff: true)

        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(ended, now: now), .done)
        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(running, now: now), .scheduled)
        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(strayFlag, now: now), .overdue)
    }

    func testAnOrdinaryJobPastItsEndIsStillOverdue() {
        let late = job(id: "a", from: (9, 15), to: (9, 15))
        let started = job(id: "b", from: (10, 0), to: (12, 0))
        let closed = job(id: "c", from: (8, 0), to: (9, 0), status: "done")

        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(late, now: now), .overdue)
        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(started, now: now), .inProgress)
        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(closed, now: now), .done)
    }

    // MARK: - The ladder on a multi-day run

    func testAnEarlierDayOfARunIsInProgressRatherThanOverdue() {
        // Day 1 of a three-day job, worked 9–17, read at 18:00 that evening.
        // `end` is that DAY's close, not the run's, so an ungated `now > end`
        // called it overdue while the phone read `in_progress`.
        let dayOne = job(
            id: "a", from: (9, 0), to: (17, 0), dayIndex: 1, dayCount: 3)
        let dayTwo = job(
            id: "b", day: 11, from: (9, 0), to: (17, 0),
            dayIndex: 2, dayCount: 3)
        let lastDay = job(
            id: "c", day: 12, from: (9, 0), to: (17, 0),
            dayIndex: 3, dayCount: 3)

        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(
                dayOne, now: at(day: 10, hour: 18)),
            .inProgress)
        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(
                dayTwo, now: at(day: 11, hour: 18)),
            .inProgress)
        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(
                lastDay, now: at(day: 12, hour: 18)),
            .overdue)
    }

    func testAMultiDayBlockCompletesItselfOnlyAfterItsLastDay() {
        let monday = job(
            id: "a", from: (0, 0), to: (23, 59), personal: true, dayOff: true,
            dayIndex: 1, dayCount: 5)
        let friday = job(
            id: "b", day: 14, from: (0, 0), to: (23, 59), personal: true,
            dayOff: true, dayIndex: 5, dayCount: 5)

        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(
                monday, now: at(day: 11, hour: 0, minute: 30)),
            .scheduled)
        XCTAssertEqual(
            CarPlayTemplateBuilder.displayState(
                friday, now: at(day: 15, hour: 0, minute: 30)),
            .done)
    }

    func testAbsentRunCountersMeanTheJobIsItsOwnLastDay() {
        let single = job(id: "a", from: (9, 15), to: (9, 15))

        XCTAssertTrue(CarPlayTemplateBuilder.isLastDay(of: single))
        XCTAssertTrue(
            CarPlayTemplateBuilder.isLastDay(
                of: job(
                    id: "b", from: (9, 0), to: (10, 0),
                    dayIndex: 3, dayCount: 3)))
        XCTAssertFalse(
            CarPlayTemplateBuilder.isLastDay(
                of: job(
                    id: "c", from: (9, 0), to: (10, 0),
                    dayIndex: 1, dayCount: 3)))
    }

    func testTheLadderReachesTheRowAccessory() {
        let late = job(id: "a", from: (9, 15), to: (9, 15))
        let block = job(id: "b", from: (9, 0), to: (9, 15), personal: true)

        let lateRow = CarPlayTemplateBuilder.row(
            for: late, snapshot: snapshot(days: []), now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())
        let blockRow = CarPlayTemplateBuilder.row(
            for: block, snapshot: snapshot(days: []), now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())

        XCTAssertNotNil(lateRow.accessoryImage)
        XCTAssertNil(blockRow.accessoryImage)
        XCTAssertEqual(blockRow.accessoryType, .disclosureIndicator)
    }

    // MARK: - The own-job ring

    func testTheRingMatchesACrewNameCaseInsensitively() {
        let mine = job(
            id: "a", from: (8, 0), to: (9, 0),
            crew: [
                SnapshotCrewMember(name: "Marc Cloutier", colorValue: nil),
                SnapshotCrewMember(name: "Luc Bergeron", colorValue: 0xFF00_5CC8),
            ])

        XCTAssertTrue(
            CarPlayTemplateBuilder.isOwnJob(mine, viewerName: "Luc Bergeron"))
        XCTAssertTrue(
            CarPlayTemplateBuilder.isOwnJob(mine, viewerName: "luc bergeron"))
    }

    func testNothingRingsWithoutAViewer() {
        let assigned = job(
            id: "a", from: (8, 0), to: (9, 0),
            crew: [SnapshotCrewMember(name: "Luc Bergeron", colorValue: nil)])
        // An unnamed assignee resolves to an empty crew name, which must not
        // match an empty viewer either.
        let unnamed = job(
            id: "b", from: (8, 0), to: (9, 0),
            crew: [SnapshotCrewMember(name: "", colorValue: nil)])

        XCTAssertFalse(
            CarPlayTemplateBuilder.isOwnJob(assigned, viewerName: nil))
        XCTAssertFalse(
            CarPlayTemplateBuilder.isOwnJob(unnamed, viewerName: ""))
    }

    func testNothingRingsOnAJobTheViewerIsNotOn() {
        let theirs = job(
            id: "a", from: (8, 0), to: (9, 0),
            crew: [SnapshotCrewMember(name: "Marc Cloutier", colorValue: nil)])
        let unassigned = job(id: "b", from: (8, 0), to: (9, 0))

        XCTAssertFalse(
            CarPlayTemplateBuilder.isOwnJob(theirs, viewerName: "Luc Bergeron"))
        XCTAssertFalse(
            CarPlayTemplateBuilder.isOwnJob(
                unassigned, viewerName: "Luc Bergeron"))
    }

    // MARK: - In-place refresh

    func testSectionBuildersMatchTheRootTemplateTabs() {
        let data = snapshot(role: "admin", viewer: "Luc Bergeron", days: [
            day(10, [
                job(id: "on", from: (10, 0), to: (12, 0), status: "in_progress"),
                job(id: "late", from: (9, 15), to: (9, 15)),
                job(id: "l1", from: (13, 30), to: (14, 30)),
            ]),
            day(11, [job(id: "fri", day: 11, from: (13, 0), to: (14, 0))]),
        ])
        let look = CarPlayPresentation(viewerName: data.viewer)
        let root = CarPlayTemplateBuilder.rootTemplate(
            snapshot: data, now: now,
            presentation: look, actions: CarPlayActions())
        let tabs = root.templates.compactMap { $0 as? CPListTemplate }

        let today = CarPlayTemplateBuilder.todaySections(
            snapshot: data, now: now,
            presentation: look, actions: CarPlayActions())
        let week = CarPlayTemplateBuilder.weekSections(
            snapshot: data, now: now,
            presentation: look, actions: CarPlayActions())

        XCTAssertEqual(today.count, 3)
        XCTAssertEqual(week.count, 1)
        XCTAssertEqual(describe(tabs[0].sections), describe(today))
        XCTAssertEqual(describe(tabs[1].sections), describe(week))
    }

    func testRefreshingATabReplacesItsSectionsInPlace() {
        let empty = snapshot(days: [day(10, []), day(11, [])])
        let filled = snapshot(days: [
            day(10, [job(id: "a", from: (13, 30), to: (14, 30))]),
        ])
        let template = CarPlayTemplateBuilder.todayTemplate(
            snapshot: empty, now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())
        XCTAssertTrue(template.sections.isEmpty)

        CarPlayTemplateBuilder.refreshToday(
            template, snapshot: filled, now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())

        XCTAssertEqual(
            describe(template.sections),
            describe(
                CarPlayTemplateBuilder.todaySections(
                    snapshot: filled, now: now,
                    presentation: CarPlayPresentation(),
                    actions: CarPlayActions())))
        XCTAssertEqual(template.tabTitle, CarPlayStrings.todayTab)
    }

    func testRefreshSkipsAnUpdateThatWouldDrawTheSameRows() {
        let data = snapshot(days: [
            day(10, [job(id: "a", from: (10, 30), to: (11, 30))]),
        ])
        let template = CarPlayTemplateBuilder.todayTemplate(
            snapshot: data, now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())
        let installed = template.sections

        let unchanged = CarPlayTemplateBuilder.refreshToday(
            template, snapshot: data, now: now,
            presentation: CarPlayPresentation(), actions: CarPlayActions())
        let sectionsUntouched = installed[0] === template.sections[0]
        // A minute on, "Starts in 18 min" reads 17, so this one must land.
        let moved = CarPlayTemplateBuilder.refreshToday(
            template, snapshot: data, now: at(day: 10, hour: 10, minute: 13),
            presentation: CarPlayPresentation(), actions: CarPlayActions())

        XCTAssertFalse(unchanged)
        XCTAssertTrue(sectionsUntouched)
        XCTAssertTrue(moved)
        XCTAssertFalse(installed[0] === template.sections[0])
    }

    func testTheRenderKeySeesWhatOnlyTheTILEDraws() {
        // A technician row's start time lives in the tile, not in either
        // string. These two Later sections agree on every header, every row
        // title and every second line — only the tile differs.
        let fixed = [
            job(id: "on", from: (9, 0), to: (12, 0), status: "in_progress"),
            job(id: "next", from: (13, 0), to: (14, 0)),
        ]
        let look = CarPlayPresentation()
        let before = CarPlayTemplateBuilder.todaySections(
            snapshot: snapshot(days: [
                day(10, fixed + [job(id: "l", from: (16, 30), to: (17, 30))]),
            ]),
            now: now, presentation: look, actions: CarPlayActions())
        let after = CarPlayTemplateBuilder.todaySections(
            snapshot: snapshot(days: [
                day(10, fixed + [job(id: "l", from: (17, 30), to: (18, 30))]),
            ]),
            now: now, presentation: look, actions: CarPlayActions())

        XCTAssertEqual(describe(before), describe(after))
        XCTAssertNotEqual(
            CarPlayTemplateBuilder.renderKey(before),
            CarPlayTemplateBuilder.renderKey(after))
    }

    // MARK: - Snapshot schema

    func testCrewDecodesWhenPresentAndIsOptionalWhenNot() throws {
        let decoder = JSONDecoder()
        let withCrew = """
        {"id":"a","startMillis":0,"endMillis":1,"clientName":"T","address":"",
         "status":"pending","crew":[{"n":"Marc Cloutier","c":4286578816}]}
        """
        let withoutCrew = """
        {"id":"a","startMillis":0,"endMillis":1,"clientName":"T","address":"",
         "status":"pending"}
        """
        // The Dart builder OMITS `c` when the roster has no colour for that
        // assignee; a required Int would fail the whole snapshot decode.
        let colourlessCrew = """
        {"id":"a","startMillis":0,"endMillis":1,"clientName":"T","address":"",
         "status":"pending","crew":[{"n":"Marc Cloutier"}]}
        """

        let decoded = try decoder.decode(
            SnapshotAppointment.self, from: Data(withCrew.utf8))
        let legacy = try decoder.decode(
            SnapshotAppointment.self, from: Data(withoutCrew.utf8))
        let colourless = try decoder.decode(
            SnapshotAppointment.self, from: Data(colourlessCrew.utf8))

        XCTAssertEqual(decoded.crew?.first?.name, "Marc Cloutier")
        XCTAssertEqual(decoded.crew?.first?.colorValue, 4_286_578_816)
        XCTAssertNil(legacy.crew)
        XCTAssertEqual(colourless.crew?.first?.storedColor, 0xFF00_5CC8)
    }

    func testThePersonalFlagsAreOmittedWhenFalseAndReadAsFalse() throws {
        let decoder = JSONDecoder()
        // The builder writes neither key on an ordinary client visit — unlike
        // `isAllDay`, which is always present as true or false.
        let ordinary = """
        {"id":"a","startMillis":0,"endMillis":1,"clientName":"T","address":"",
         "status":"pending","isAllDay":false}
        """
        let timeOff = """
        {"id":"a","startMillis":0,"endMillis":1,"clientName":"T","address":"",
         "status":"pending","isAllDay":true,"isPersonal":true,"isDayOff":true}
        """
        let personalOnly = """
        {"id":"a","startMillis":0,"endMillis":1,"clientName":"T","address":"",
         "status":"pending","isAllDay":false,"isPersonal":true}
        """

        let visit = try decoder.decode(
            SnapshotAppointment.self, from: Data(ordinary.utf8))
        let off = try decoder.decode(
            SnapshotAppointment.self, from: Data(timeOff.utf8))
        let block = try decoder.decode(
            SnapshotAppointment.self, from: Data(personalOnly.utf8))

        XCTAssertNil(visit.isPersonal)
        XCTAssertNil(visit.isDayOff)
        XCTAssertFalse(visit.personal)
        XCTAssertFalse(visit.dayOff)
        XCTAssertFalse(visit.isTimeOff)
        XCTAssertTrue(off.isTimeOff)
        XCTAssertTrue(block.personal)
        XCTAssertFalse(block.isTimeOff)
    }

    func testViewerDecodesOnAnAdminSnapshotAndIsAbsentOtherwise() throws {
        let decoder = JSONDecoder()
        let admin = """
        {"version":4,"generatedAt":0,"role":"admin","viewer":"Luc Bergeron",
         "days":[]}
        """
        // v3 is still on disk until the app next runs after an update, and it
        // has to keep decoding — Siri answers from the same payload.
        let legacyEmployee = """
        {"version":3,"generatedAt":0,"role":"employee","days":[]}
        """

        let seen = try decoder.decode(
            ScheduleSnapshot.self, from: Data(admin.utf8))
        let legacy = try decoder.decode(
            ScheduleSnapshot.self, from: Data(legacyEmployee.utf8))

        XCTAssertEqual(seen.viewer, "Luc Bergeron")
        XCTAssertTrue(seen.isAdmin)
        XCTAssertNil(legacy.viewer)
        // Decoding a v3 payload proves nothing about the GATE — `load()` is
        // what consults it, and that needs the App Group entitlement.
        XCTAssertTrue(ScheduleSnapshot.accepts(version: legacy.version))
        XCTAssertTrue(ScheduleSnapshot.accepts(version: seen.version))
    }

    func testTheVersionGateAcceptsBothShippingSchemasAndNothingElse() {
        // Re-tightening this to v4 alone blanks Siri AND CarPlay for every
        // user until their first launch after the update rewrites the file.
        XCTAssertTrue(ScheduleSnapshot.accepts(version: 3))
        XCTAssertTrue(ScheduleSnapshot.accepts(version: 4))

        XCTAssertFalse(ScheduleSnapshot.accepts(version: 0))
        XCTAssertFalse(ScheduleSnapshot.accepts(version: 2))
        XCTAssertFalse(ScheduleSnapshot.accepts(version: 5))
        XCTAssertFalse(ScheduleSnapshot.accepts(version: -1))
    }
}
