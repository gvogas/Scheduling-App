// ScheduleWidget — iOS home-screen widget for the employee's schedule.
//
// Reads the JSON payload the Flutter app writes into the shared App Group
// (`group.net.vogas.scheduling`, key `schedulePayload`) via home_widget, and
// renders the "System Card" design: small = next job, medium/large = the day's
// job list.
//
// The payload carries both today's and tomorrow's jobs plus a `rolloverAt`
// instant. The timeline seeds an entry at that instant so the widget flips
// from today to tomorrow ON-DEVICE (no app run or push needed) about an
// hour after the day's last job finishes (see buildWidgetPayload in
// widget_sync_service.dart).
//
// This file is compiled only on macOS/Xcode (see the Mac handoff runbook).

import SwiftUI
import WidgetKit

// MARK: - Payload model

private let appGroupId = "group.net.vogas.scheduling"
private let payloadKey = "schedulePayload"

// The Flutter side emits UTC instants with milliseconds
// (e.g. 2026-07-11T18:30:00.000Z). The default ISO8601DateFormatter can't
// parse that unless `.withFractionalSeconds` is set, so we try the
// fractional-seconds format first and fall back to the no-millis form.
private let isoWithMillis: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoNoMillis = ISO8601DateFormatter()

struct Job: Codable, Hashable {
    let id: String
    let startTime: String
    let clientName: String
    let title: String
    let address: String
    let status: String
    // Optional so a payload written before all-day blocks existed still
    // decodes — a missing key would fail the whole `Job` otherwise. Read it
    // through `allDay`, never directly.
    let isAllDay: Bool?

    // Optional for the same reason as `isAllDay` — a payload written before
    // multi-day support carries neither key, and a missing one would fail the
    // whole `Job`. Absent means a single-day job; both builders omit them
    // rather than sending 1 of 1.
    let dayIndex: Int?
    let dayCount: Int?
    var endTime: String? = nil

    /// True for an all-day block, which stores a real midnight–23:59 span but
    /// must never be spoken as a clock time.
    var allDay: Bool { isAllDay == true }

    /// True when this job runs across more than one day, so the row names
    /// which day of the run it is showing.
    var isMultiDay: Bool { (dayCount ?? 1) > 1 }

    var start: Date? {
        isoWithMillis.date(from: startTime)
            ?? isoNoMillis.date(from: startTime)
    }

    /// Deep link into the app's calendar for this appointment. The Flutter
    /// side (home_widget `widgetClicked`) opens the detail sheet via the
    /// scheme registered in Info.plist (`CFBundleURLTypes`).
    /// `homeWidget` is load-bearing: the home_widget plugin's `isWidgetUrl`
    /// claims only URLs carrying that query item, and nothing else consumes
    /// the scheme (`FlutterDeepLinkingEnabled` is false). Drop it only when
    /// the P4b app_links dispatcher replaces the home_widget tap channel.
    var deepLink: URL? {
        URL(string: "esproschedule://appointment?id=\(id)&homeWidget")
    }
}

private func parseInstant(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return isoWithMillis.date(from: s) ?? isoNoMillis.date(from: s)
}

struct SchedulePayload: Codable {
    let locale: String
    let generatedAt: String
    let todayDate: String?
    let tomorrowDate: String?
    // When to switch from today to tomorrow — 1h after the day's last job
    // finishes. It's nil while any job is still open, so the widget stays on
    // today.
    let rolloverAt: String?
    let todayJobs: [Job]?
    let tomorrowJobs: [Job]?
    var ownerUid: String? = nil
    var sessionEpoch: String? = nil

    /// The day (today or tomorrow) the widget should render at `date`, resolved
    /// purely from the payload so a future timeline entry can flip on-device.
    func resolved(at date: Date) -> DaySchedule {
        guard matchesCurrentOwner else {
            return DaySchedule(headerDate: date, isTomorrow: false, jobs: [], needsSync: true)
        }
        let calendar = Calendar.current
        let today = parseInstant(todayDate)
        let tomorrow = parseInstant(tomorrowDate)
        let onTomorrow = tomorrow.map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        let onToday = today.map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        guard onToday || onTomorrow else {
            return DaySchedule(headerDate: date, isTomorrow: false, jobs: [], needsSync: true)
        }
        func remaining(_ jobs: [Job]) -> [Job] {
            jobs.filter { job in
                guard !["done", "completed", "cancelled"].contains(job.status.lowercased()) else { return false }
                if job.allDay {
                    let fallbackEnd = calendar.date(byAdding: .day, value: 1,
                        to: calendar.startOfDay(for: job.start ?? date)) ?? date
                    return (parseInstant(job.endTime) ?? fallbackEnd) > date
                }
                return (parseInstant(job.endTime) ?? job.start ?? .distantPast) > date
            }
        }
        if onTomorrow || (parseInstant(rolloverAt).map { date >= $0 } ?? false) {
            return DaySchedule(
                headerDate: parseInstant(tomorrowDate) ?? date,
                isTomorrow: !onTomorrow,
                jobs: remaining(tomorrowJobs ?? []))
        }
        return DaySchedule(
            headerDate: parseInstant(todayDate) ?? date,
            isTomorrow: false,
            jobs: remaining(todayJobs ?? []))
    }

    private var matchesCurrentOwner: Bool {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let raw = defaults.string(forKey: "schedule_session_owner"),
              let data = raw.data(using: .utf8),
              let binding = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = binding["ownerUid"] as? String,
              let epoch = binding["epoch"] as? String else { return false }
        return ownerUid == uid && sessionEpoch == epoch
    }

    static func load() -> SchedulePayload? {
        guard
            let defaults = UserDefaults(suiteName: appGroupId),
            let raw = defaults.string(forKey: payloadKey),
            let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(SchedulePayload.self, from: data)
    }
}

/// The resolved single-day view the widget renders for a given timeline entry.
struct DaySchedule {
    let headerDate: Date
    let isTomorrow: Bool
    let jobs: [Job]
    var needsSync = false

    /// An all-day block is listed, but it is never "next" while a timed job
    /// remains — it starts at midnight, so it would otherwise own the
    /// "up next" slot all day and hide the real next visit.
    var nextJob: Job? { jobs.first(where: { !$0.allDay }) ?? jobs.first }
    var count: Int { jobs.count }

    static let empty = DaySchedule(
        headerDate: Date(), isTomorrow: false, jobs: [])
}

// MARK: - Timeline

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let payload: SchedulePayload?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry {
        ScheduleEntry(date: Date(), payload: nil)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (ScheduleEntry) -> Void
    ) {
        completion(ScheduleEntry(date: Date(), payload: SchedulePayload.load()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<ScheduleEntry>) -> Void
    ) {
        let payload = SchedulePayload.load()
        let now = Date()
        // One entry at now, one at each future job start (so times/relative
        // labels refresh), and — crucially — one at the rollover instant so the
        // widget flips from today to tomorrow with the app closed.
        var dates: Set<Date> = [now]
        for offset in 1...2 {
            if let midnight = Calendar.current.date(byAdding: .day, value: offset,
                to: Calendar.current.startOfDay(for: now)) { dates.insert(midnight) }
        }
        if let payload = payload {
            for job in payload.todayJobs ?? [] {
                if let start = job.start, start > now { dates.insert(start) }
                if let end = parseInstant(job.endTime), end > now { dates.insert(end) }
            }
            for job in payload.tomorrowJobs ?? [] {
                if let start = job.start, start > now { dates.insert(start) }
                if let end = parseInstant(job.endTime), end > now { dates.insert(end) }
            }
            if let rollover = parseInstant(payload.rolloverAt),
                rollover > now {
                dates.insert(rollover)
            }
        }
        let entries = dates.sorted().map {
            ScheduleEntry(date: $0, payload: payload)
        }
        // Refresh again in an hour as a floor.
        let refresh = Calendar.current.date(
            byAdding: .hour, value: 1, to: now) ?? now
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

// MARK: - Localization helpers

private func emptyLabel(french: Bool, tomorrow: Bool) -> String {
    if french {
        return tomorrow ? "Aucune visite demain" : "Aucune visite aujourd'hui"
    }
    return tomorrow ? "No jobs tomorrow" : "No jobs today"
}

private func moreLabel(_ n: Int, french: Bool, tomorrow: Bool) -> String {
    if french {
        return tomorrow ? "+\(n) autres demain" : "+\(n) autres aujourd'hui"
    }
    return tomorrow ? "+\(n) more tomorrow" : "+\(n) more today"
}

private func timeLabel(_ job: Job, french: Bool) -> String {
    let base: String
    if job.allDay {
        base = french ? "Toute la journée" : "All day"
    } else if let start = job.start {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: french ? "fr_CA" : "en_CA")
        fmt.dateFormat = french ? "H 'h' mm" : "h:mm a"
        base = fmt.string(from: start)
    } else {
        base = ""
    }
    // A run whose window crosses midnight counts nights, but the widget
    // payload carries no overnight flag, so it says "Day" either way.
    guard job.isMultiDay, let i = job.dayIndex, let n = job.dayCount else {
        return base
    }
    let counter = french ? "Jour \(i) sur \(n)" : "Day \(i) of \(n)"
    return base.isEmpty ? counter : "\(base) · \(counter)"
}

private func statusColor(_ status: String) -> Color {
    switch status.lowercased() {
    case "done", "completed": return .green
    case "in_progress": return Color(red: 0.0, green: 0.65, blue: 0.96)
    case "cancelled": return .red
    default: return .orange // pending
    }
}

// MARK: - Views

struct DateHeader: View {
    let date: Date
    let french: Bool

    var body: some View {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: french ? "fr_CA" : "en_CA")
        fmt.dateFormat = french ? "EEEE d MMMM" : "EEEE, MMM d"
        return Text(fmt.string(from: date).uppercased())
            .font(.caption2).bold()
            .foregroundColor(.red)
            .lineLimit(1)
    }
}

struct JobRow: View {
    let job: Job
    let french: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor(job.status))
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.clientName.isEmpty ? job.title : job.clientName)
                    .font(.footnote).bold()
                    .lineLimit(1)
                Text(timeLabel(job, french: french))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct SmallView: View {
    let day: DaySchedule
    let french: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DateHeader(date: day.headerDate, french: french)
            if let next = day.nextJob {
                Text(next.clientName.isEmpty ? next.title : next.clientName)
                    .font(.headline).lineLimit(1)
                Text(timeLabel(next, french: french))
                    .font(.subheadline).bold()
                    .foregroundColor(Color(red: 0.08, green: 0.4, blue: 0.75))
                    .lineLimit(1)
                    // "Toute la journée" is long for the small widget's
                    // width; shrink rather than truncate it.
                    .minimumScaleFactor(0.8)
                if !next.address.isEmpty {
                    Text(next.address).font(.caption2)
                        .foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(remainingFooter())
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            } else {
                Spacer()
                Label(
                    emptyLabel(french: french, tomorrow: day.isTomorrow),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.footnote).foregroundColor(.green).lineLimit(1)
                Spacer()
            }
        }
        .padding(12)
    }

    private func remainingFooter() -> String {
        let count = day.count
        if day.isTomorrow {
            if french {
                return count == 1 ? "1 demain" : "\(count) demain"
            }
            return count == 1 ? "1 tomorrow" : "\(count) tomorrow"
        }
        if french {
            return count == 1 ? "1 restante aujourd'hui"
                : "\(count) restantes aujourd'hui"
        }
        return count == 1 ? "1 left today" : "\(count) left today"
    }
}

struct ListView: View {
    let day: DaySchedule
    let french: Bool
    let maxRows: Int

    var body: some View {
        let tomorrow = day.isTomorrow
        let jobs = day.jobs
        return VStack(alignment: .leading, spacing: 8) {
            DateHeader(date: day.headerDate, french: french)
            if jobs.isEmpty {
                Spacer()
                Label(
                    emptyLabel(french: french, tomorrow: tomorrow),
                    systemImage: "checkmark.circle.fill"
                ).font(.footnote).foregroundColor(.green).lineLimit(1)
                Spacer()
            } else {
                ForEach(jobs.prefix(maxRows), id: \.self) { job in
                    if let url = job.deepLink {
                        Link(destination: url) {
                            JobRow(job: job, french: french)
                        }
                    } else {
                        JobRow(job: job, french: french)
                    }
                }
                if jobs.count > maxRows {
                    Text(moreLabel(
                        jobs.count - maxRows, french: french,
                        tomorrow: tomorrow))
                        .font(.caption2).foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }
}

struct ScheduleWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: Provider.Entry

    // Resolve which day to show FOR THIS ENTRY'S DATE. A future entry seeded
    // at the rollover instant renders tomorrow, even though the payload
    // itself was written earlier — while it was still today, either with the
    // app open or by a push.
    private var day: DaySchedule {
        entry.payload?.resolved(at: entry.date) ?? .empty
    }
    private var french: Bool { entry.payload?.locale == "fr" }

    var body: some View {
        content.widgetContainerBackground()
    }

    @ViewBuilder
    private var content: some View {
        if day.needsSync || entry.payload == nil {
            Text(french ? "Ouvrez ES Pro pour actualiser l'horaire." : "Open ES Pro to refresh your schedule.")
        } else {
        switch family {
        case .systemSmall:
            // systemSmall can't host per-row Links, so the whole widget links
            // to the shown "next job" (falls back to a plain app launch when
            // there's none).
            SmallView(day: day, french: french)
                .widgetURL(day.nextJob?.deepLink)
        case .systemLarge:
            ListView(day: day, french: french, maxRows: 6)
        default:
            ListView(day: day, french: french, maxRows: 3)
        }
        }
    }
}

extension View {
    /// iOS 17 requires a declared container background, or widgets render a
    /// "Please adopt containerBackground" placeholder. This is gated so it
    /// still compiles at the iOS 15 deployment target, and uses `.background`
    /// to match the phone's light/dark mode.
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(.background, for: .widget)
        } else {
            self
        }
    }
}

// MARK: - Widget

struct ScheduleWidget: Widget {
    let kind = "ScheduleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ScheduleWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Schedule")
        .description("Your next job and today's schedule.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Bundle

// Hosting an ActivityConfiguration alongside the home-screen widget requires
// @main on a WidgetBundle rather than on either widget.
@main
struct ScheduleWidgetBundle: WidgetBundle {
    var body: some Widget {
        ScheduleWidget()
        if #available(iOS 17.2, *) {
            JobLiveActivity()
        }
    }
}
