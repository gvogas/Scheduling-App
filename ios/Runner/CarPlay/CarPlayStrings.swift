// CarPlayStrings — CarPlay display text in English and French.
//
// Plain Swift rather than a string catalog, mirroring
// ios/SiriIntents/SiriStrings.swift, so both localizations sit side by side and
// review in one place. It does NOT mirror that file's language SOURCE: Siri
// speaks in the device's Siri language, while this is app chrome and follows
// the app's own language switch (`AppLanguageController`), which a user can set
// to French on an English-region phone.
//
// Times are 12-hour in BOTH locales (owner call, 2026-09-10).
//
// This file is compiled only on macOS/Xcode.

import Foundation

enum CarPlayStrings {
    /// `shared_preferences` writes the app's language into the app's OWN
    /// standard defaults under its `flutter.` prefix, and the CarPlay scene
    /// runs in that same process — no App Group field and no channel call.
    private static let languageKey = "flutter.language"

    /// The app's chosen language, falling back to the device when the user has
    /// never picked one (the preference is written only on an explicit choice).
    static var french: Bool {
        if let chosen = UserDefaults.standard.string(forKey: languageKey) {
            return chosen.hasPrefix("fr")
        }
        return Locale.current.identifier.hasPrefix("fr")
    }

    private static var locale: Locale {
        Locale(identifier: french ? "fr_CA" : "en_CA")
    }

    // MARK: - Formatting

    /// Pinned AM/PM symbols: `en_CA` renders "a.m." and `fr_CA` "AM" by default.
    static func time(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.dateFormat = "h:mm a"
        fmt.amSymbol = "AM"
        fmt.pmSymbol = "PM"
        return fmt.string(from: date)
    }

    static func weekday(_ date: Date) -> String {
        capitalizedFirst(format(date, "EEEE"))
    }

    static func dayAndMonth(_ date: Date) -> String { format(date, "d MMMM") }

    static func weekdayAndDate(_ date: Date) -> String {
        capitalizedFirst(format(date, "EEEE d MMMM"))
    }

    /// "Today" / "Tomorrow", else the weekday-and-date form. Display text, so
    /// it is capitalized — unlike `SiriStrings.relativeDay`, which is spoken.
    static func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return french ? "Aujourd'hui" : "Today" }
        if cal.isDateInTomorrow(date) { return french ? "Demain" : "Tomorrow" }
        return weekdayAndDate(date)
    }

    static func minutesPhrase(_ minutes: Int) -> String {
        let total = max(minutes, 1)
        if total < 60 { return "\(total) min" }
        let hours = total / 60
        let rest = total % 60
        if french {
            return rest == 0 ? "\(hours) h" : "\(hours) h \(rest)"
        }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    static func jobCount(_ count: Int) -> String {
        if french {
            return count == 1 ? "1 travail" : "\(count) travaux"
        }
        return count == 1 ? "1 job" : "\(count) jobs"
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.dateFormat = pattern
        return fmt.string(from: date)
    }

    /// French weekday and month names come back lowercase, which is correct
    /// prose and wrong for a section title.
    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    // MARK: - Tabs and list titles

    static var todayTab: String { french ? "Aujourd'hui" : "Today" }
    static var weekTab: String { french ? "Semaine" : "Week" }

    // MARK: - Section headers

    static var nowSection: String { french ? "Maintenant" : "Now" }
    static var nextSection: String { french ? "Prochain" : "Next" }
    static var laterSection: String {
        french ? "Plus tard aujourd'hui" : "Later today"
    }
    static var tomorrowSection: String { french ? "Demain" : "Tomorrow" }

    /// Nil for an all-day block: it starts at midnight, so "Started 12:00 AM"
    /// names a time it does not have.
    static func startedAt(_ appointment: SnapshotAppointment) -> String? {
        guard !appointment.allDay else { return nil }
        let clock = time(appointment.start)
        return french ? "Débuté à \(clock)" : "Started \(clock)"
    }

    static func onSite(_ count: Int) -> String {
        french ? "\(count) sur place" : "\(count) on site"
    }

    /// The Next header's countdown, and the detail screen's When tail. One
    /// owner so the two can never disagree about how late a job is.
    /// Under this, the tail counts down; at or over it, it names the clock time.
    static let nearTermWindow: TimeInterval = 3600

    static func countdown(start: Date, end: Date, now: Date) -> String {
        if now < start {
            let minutes = Int((start.timeIntervalSince(now) / 60).rounded())
            if start.timeIntervalSince(now) < nearTermWindow {
                return french
                    ? "Débute dans \(minutesPhrase(minutes))"
                    : "Starts in \(minutesPhrase(minutes))"
            }
            return french ? "Débute à \(time(start))" : "Starts at \(time(start))"
        }
        if now <= end { return french ? "À faire maintenant" : "Due now" }
        let minutes = Int((now.timeIntervalSince(end) / 60).rounded())
        return french
            ? "En retard de \(minutesPhrase(minutes))"
            : "Overdue by \(minutesPhrase(minutes))"
    }

    static func laterSubtitle(more: Int, done: Int) -> String {
        let head: String
        if french {
            head = more == 1 ? "1 autre travail" : "\(more) autres travaux"
        } else {
            head = more == 1 ? "1 more job" : "\(more) more jobs"
        }
        guard done > 0 else { return head }
        let tail: String
        if french {
            tail = done == 1 ? "1 terminé" : "\(done) terminés"
        } else {
            tail = "\(done) done"
        }
        return "\(head) · \(tail)"
    }

    /// "Friday 11 September · 3 jobs" for tomorrow, whose header says only
    /// "Tomorrow"; "14 September · 2 jobs" where the header is the weekday.
    static func daySubtitle(
        _ date: Date, count: Int, includeWeekday: Bool
    ) -> String {
        let when = includeWeekday ? weekdayAndDate(date) : dayAndMonth(date)
        return "\(when) · \(jobCount(count))"
    }


    // MARK: - Row and state vocabulary


    /// Who a row is named after: the client, then the job title, then a
    /// generic label. Mirrors `SiriStrings.who`, capitalized for display.
    static func who(_ appointment: SnapshotAppointment) -> String {
        let title = (appointment.title ?? "")
            .trimmingCharacters(in: .whitespaces)
        // Trimmed on BOTH sides: a whitespace-only client name is not a name,
        // and untrimmed it renders as a blank row heading.
        let client = appointment.clientName
            .trimmingCharacters(in: .whitespaces)
        let name = client.isEmpty ? title : client
        if !name.isEmpty { return name }
        return french ? "Client sans nom" : "Unnamed client"
    }

    /// Line two: the job title, then the address, which truncates from the
    /// right. An empty title lets the address take the line.
    /// The detail heading: client then job title when BOTH exist, since `who`
    /// already falls back to whichever one is present.
    static func detailTitle(_ appointment: SnapshotAppointment) -> String {
        let title = (appointment.title ?? "")
            .trimmingCharacters(in: .whitespaces)
        let client = appointment.clientName
            .trimmingCharacters(in: .whitespaces)
        guard !client.isEmpty, !title.isEmpty else { return who(appointment) }
        return "\(client) · \(title)"
    }

    static func detailLine(_ appointment: SnapshotAppointment) -> String? {
        let title = (appointment.title ?? "")
            .trimmingCharacters(in: .whitespaces)
        let address = appointment.address
            .trimmingCharacters(in: .whitespaces)
        // The title already named the row when there is no client, so
        // repeating it on line two would say the same thing twice. Trimmed to
        // agree with `who`, which treats a blank client name as absent.
        let titleIsRowName = appointment.clientName
            .trimmingCharacters(in: .whitespaces).isEmpty
        if title.isEmpty || titleIsRowName {
            return address.isEmpty ? nil : address
        }
        return address.isEmpty ? title : "\(title) · \(address)"
    }

    /// Admin line one — the time and the client, since the image slot is
    /// spent on the crew avatar and the time cannot be styled separately.
    /// Both roles lead the row with the time (decision 22). An all-day block
    /// has no clock time to lead with.
    static func rowTitle(_ appointment: SnapshotAppointment) -> String {
        appointment.allDay
            ? who(appointment)
            : "\(time(appointment.start))  \(who(appointment))"
    }

    // MARK: - Detail screen

    static var whenLabel: String { french ? "Quand" : "When" }
    static var whereLabel: String { french ? "Adresse" : "Where" }
    static var crewLabel: String { french ? "Équipe" : "Crew" }

    static func whenValue(_ appointment: SnapshotAppointment, now: Date) -> String {
        let day = relativeDay(appointment.start)
        let clock = appointment.allDay
            ? (french ? "toute la journée" : "all day")
            : "\(time(appointment.start)) – \(time(appointment.end))"
        // A far-off job's tail is only its start time: redundant beside a range
        // that already shows it, and meaningless on an all-day block, whose
        // start is midnight.
        let namesOnlyTheStartTime = appointment.start > now
            && appointment.start.timeIntervalSince(now) >= nearTermWindow
        guard !namesOnlyTheStartTime else { return "\(day), \(clock)" }
        let tail = countdown(
            start: appointment.start, end: appointment.end, now: now)
        return "\(day), \(clock) · \(tail)"
    }

    static func crewValue(_ crew: [SnapshotCrewMember]) -> String {
        crew.map(\.name).joined(separator: ", ")
    }

    // MARK: - Buttons

    static var directions: String { french ? "Itinéraire" : "Directions" }
    static var startJob: String { french ? "Démarrer" : "Start job" }
    static var markComplete: String { french ? "Terminer" : "Mark complete" }
    static var call: String { french ? "Appeler" : "Call" }

    // MARK: - Empty views

    static var todayEmptyTitle: String {
        french ? "Aucun travail aujourd'hui" : "No jobs today"
    }

    static func todayEmptyNext(_ appointment: SnapshotAppointment) -> String {
        let day = relativeDay(appointment.start)
        let when = appointment.allDay
            ? day
            : "\(day) \(time(appointment.start))"
        return french
            ? "Prochain : \(when), \(who(appointment))"
            : "Next: \(when), \(who(appointment))"
    }

    static var nothingAheadSubtitle: String {
        french
            ? "Rien de prévu dans les 7 prochains jours."
            : "Nothing scheduled in the next 7 days."
    }

    static var weekEmptyTitle: String {
        french ? "Rien de prévu cette semaine" : "Nothing scheduled this week"
    }

    static var weekEmptySubtitle: String {
        french
            ? "Vos 7 prochains jours sont libres."
            : "Your next 7 days are clear."
    }

    static var signedOutTitle: String {
        french ? "Connectez-vous sur votre iPhone" : "Sign in on your iPhone"
    }

    static var signedOutSubtitle: String {
        french
            ? "Connectez-vous sur votre iPhone pour voir votre horaire."
            : "Sign in on your iPhone to see your schedule."
    }

    // MARK: - Failure alerts

    static var couldNotUpdateJob: String {
        french
            ? "Impossible de mettre à jour le travail. Réessayez."
            : "Couldn't update the job. Try again."
    }

    static var couldNotOpenJob: String {
        french
            ? "Impossible d'ouvrir ce travail. Réessayez."
            : "Couldn't open that job. Try again."
    }

    /// The short variant every failure alert falls back to on a narrow unit.
    static var couldNotDoThatShort: String {
        french ? "Action impossible" : "Couldn't do that"
    }

    static var okAction: String { "OK" }

}
