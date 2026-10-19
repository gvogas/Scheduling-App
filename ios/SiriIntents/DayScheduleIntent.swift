// "Read my schedule for a day in ES Pro" → Siri asks "For what day?"
//
// Reads an arbitrary day's bucket out loud. It's a pure projection over the
// snapshot's today+7 window, with no schema change from the Phase-1 read
// intents — "today" and "tomorrow" already have their own deterministic
// intents, so this one covers the rest.
//
// A `Date` parameter can't be interpolated into a spoken phrase — Siri only
// allows AppEnum/AppEntity there. So Siri resolves `targetDate` via its own
// locale-aware prompt, and we map it to a `days[]` bucket by local calendar
// day. Outside that window, we answer "I only have your schedule for the
// next 7 days."
//
// Answers from the App Group snapshot only — no network, no Firebase.
// This file is compiled only on macOS/Xcode.

import AppIntents

@available(iOS 16.0, *)
struct DayScheduleIntent: AppIntent {
    static var title: LocalizedStringResource = "Schedule for a day"
    static var description = IntentDescription(
        "Reads out the appointments for a given day.")

    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy =
        .alwaysAllowed

    @Parameter(
        title: "Day",
        requestValueDialog: IntentDialog(
            stringLiteral: SiriStrings.whichDayPrompt))
    var targetDate: Date

    static var parameterSummary: some ParameterSummary {
        Summary("Read the schedule for \(\.$targetDate)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = ScheduleSnapshot.load() else {
            return .result(dialog: IntentDialog(
                stringLiteral: SiriStrings.noData))
        }
        // No bucket for this day → it falls outside the today…+7 window the
        // snapshot carries (or it's in the past).
        guard let bucket = snapshot.day(on: targetDate) else {
            return .result(dialog: IntentDialog(
                stringLiteral: SiriStrings.outOfWindow))
        }
        let appointments = bucket.appointments
        guard !appointments.isEmpty else {
            return .result(dialog: IntentDialog(
                stringLiteral: bucket.isPartial ? SiriStrings.partialSchedule : SiriStrings.emptyDayFor(
                    targetDate, admin: snapshot.isAdmin)))
        }
        let intro = SiriStrings.scheduleIntroFor(
            appointments.count, date: targetDate, admin: snapshot.isAdmin)
        let lines = appointments.map(SiriStrings.scheduleLine)
        let tail = bucket.isPartial ? [SiriStrings.partialSchedule] : []
        let spoken = ([intro] + lines + tail).joined(separator: " ")
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }
}
