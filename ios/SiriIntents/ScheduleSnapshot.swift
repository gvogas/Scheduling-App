// ScheduleSnapshot — the read model the Siri App Intents extension answers from.
//
// The Flutter app writes this JSON into the shared App Group
// (`group.net.vogas.scheduling`, key `schedule_snapshot`) via home_widget —
// see buildScheduleSnapshot in lib/features/siri/domain/schedule_snapshot.dart.
// Keep this decoder and that builder in lockstep; they're hand-mirrored.
//
// Phases 1-3 are deliberately Firebase-free (snapshot in, speech out) for
// millisecond, offline answers — don't add a network client here without the
// Phase-4 review.
//
// This file is compiled only on macOS/Xcode (see the Mac handoff runbook).

import Foundation

private let appGroupId = "group.net.vogas.scheduling"
private let snapshotKey = "schedule_snapshot"

/// Schema versions this decoder understands. A snapshot stamped with anything
/// else is rejected outright, rather than risk a mis-decode.
///
/// v4 (CarPlay's `crew`) is additive, and BOTH are accepted on purpose: the
/// on-disk snapshot stays v3 until the app next runs after an update, and a
/// strict v4 gate would make Siri answer "no appointments" for that window.
private let supportedVersions: Set<Int> = [3, 4]

/// One assignee on an admin snapshot. Name and stored colour and nothing else
/// — no id, no phone, no email; the App Group is readable while locked.
struct SnapshotCrewMember: Codable, Hashable {
    let name: String
    /// The stored LIGHT-theme ARGB. The reader does the dark lift.
    ///
    /// Optional because the Dart builder OMITS the key when the roster has no
    /// colour for that assignee — a required Int here would fail the whole
    /// snapshot decode and blank Siri too.
    let colorValue: Int?

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case colorValue = "c"
    }

    /// Falls back to `AppColors.crewDefault`, which is what an employee with
    /// no stored `colorValue` renders as in the app.
    var storedColor: Int { colorValue ?? 0xFF00_5CC8 }
}

struct SnapshotAppointment: Codable, Hashable {
    // Non-optional on purpose: the Dart builder drops records without a doc id,
    // because a Phase-4 write action resolves its target by this id.
    let id: String
    let startMillis: Double
    let endMillis: Double
    let clientName: String
    // v2. Optional so a stale v1 snapshot still decodes far enough to be
    // rejected by the version gate rather than failing mid-decode.
    let title: String?
    let address: String
    let status: String
    let isAllDay: Bool?
    // v4. The two flags `displayStatusAt` branches on. Unlike `isAllDay` above,
    // which is always written, these are OMITTED when false — read them
    // through `personal`/`dayOff` below, never as a plain `Bool`.
    let isPersonal: Bool?
    let isDayOff: Bool?
    // v3. Optional so the decode of an older payload still reaches the version
    // gate above rather than failing field-wise. Absent means a single-day job
    // — the builder omits them rather than sending 1 of 1.
    let dayIndex: Int?
    let dayCount: Int?
    let isOvernight: Bool?
    // v4. Emitted only on an admin snapshot, where every row is somebody
    // else's; optional so a v3 payload still decodes.
    let crew: [SnapshotCrewMember]?

    var start: Date { Date(timeIntervalSince1970: startMillis / 1000) }
    var end: Date { Date(timeIntervalSince1970: endMillis / 1000) }

    /// True for an all-day block, which stores a real midnight–23:59 span but
    /// must never be read out as a clock time.
    var allDay: Bool { isAllDay == true }

    /// Somebody's own block rather than a client visit — a clinic, a school
    /// run. Absent means false, which is what an omitted key encodes.
    var personal: Bool { isPersonal == true }

    /// Meaningful only through `isTimeOff`, the same rule the app applies.
    var dayOff: Bool { isDayOff == true }

    /// Mirrors `AppointmentRecord.isTimeOff`.
    var isTimeOff: Bool { personal && dayOff }

    /// True when this job runs across more than one day, so Siri names which
    /// day of the run it is speaking about.
    var isMultiDay: Bool { (dayCount ?? 1) > 1 }

    var isDone: Bool {
        let s = status.lowercased()
        return s == "done" || s == "completed"
    }

    /// Deep link into the app's appointment detail sheet, using the scheme
    /// registered in Info.plist (`CFBundleURLTypes`) that the widget also uses.
    /// The `homeWidget` query item is required for the plugin to claim the
    /// URL — see `Job.deepLink` in ScheduleWidget.swift.
    var deepLink: URL? {
        URL(string: "esproschedule://appointment?id=\(id)&homeWidget")
    }
}

struct SnapshotDay: Codable, Hashable {
    /// Device-local calendar day, `yyyy-MM-dd`.
    let date: String
    let appointments: [SnapshotAppointment]
}

struct ScheduleSnapshot: Codable {
    let version: Int
    let generatedAt: Double
    let role: String
    /// v4. The signed-in person's own name, so the car can ring the jobs they
    /// are on. Present ONLY on an admin snapshot whose name resolved, so nil
    /// is the ordinary case and rings nothing.
    let viewer: String?
    let days: [SnapshotDay]

    var isAdmin: Bool { role == "admin" }

    /// The bucket for a given day, or nil when it falls outside the window the
    /// snapshot carries (today + 7).
    func day(on date: Date) -> SnapshotDay? {
        let key = ScheduleSnapshot.dayKey(date)
        return days.first { $0.date == key }
    }

    var today: SnapshotDay? { day(on: Date()) }

    /// Earliest upcoming visit across the whole window that hasn't been
    /// marked done. Cancelled visits are already excluded at build time.
    ///
    /// An all-day block is still eligible — it just never wins while a timed
    /// visit remains *inside its own span*. It starts at midnight, so it would
    /// otherwise be "next" for the whole day and hide the real next visit; and
    /// by the same token it stays upcoming until its 23:59 end, not its start.
    ///
    /// The "prefer timed" test is scoped to the block's own span, matching the
    /// widget's per-day `DaySchedule.nextJob`. Comparing against every timed
    /// visit in the 7-day window instead would skip today's all-day block
    /// entirely whenever *any* later day held a timed job — Siri would answer
    /// with Thursday's visit while today's block went unmentioned.
    func nextAppointment(after now: Date = Date()) -> SnapshotAppointment? {
        let upcoming = days
            .flatMap { $0.appointments }
            .filter { !$0.isDone && ($0.allDay ? $0.end > now : $0.start > now) }
        guard let earliest = upcoming.min(by: { $0.start < $1.start })
        else { return nil }
        guard earliest.allDay else { return earliest }
        let timedWithin = upcoming.filter { !$0.allDay && $0.start < earliest.end }
        return timedWithin.min { $0.start < $1.start } ?? earliest
    }

    /// Whether this decoder understands a payload stamped [version]. Separate
    /// from `load()`, which reaches `UserDefaults(suiteName:)` and so needs the
    /// App Group entitlement to run — the gate it consults does not.
    static func accepts(version: Int) -> Bool {
        supportedVersions.contains(version)
    }

    static func load() -> ScheduleSnapshot? {
        guard
            let defaults = UserDefaults(suiteName: appGroupId),
            let raw = defaults.string(forKey: snapshotKey),
            let data = raw.data(using: .utf8),
            let snapshot = try? JSONDecoder().decode(
                ScheduleSnapshot.self, from: data)
        else { return nil }
        guard accepts(version: snapshot.version) else { return nil }
        return snapshot
    }

    /// Matches the Dart builder's `_dayKey` — device-local, zero-padded.
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents(
            [.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
