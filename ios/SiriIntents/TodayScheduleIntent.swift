// "What's my schedule today in ES Pro?"
//
// Reads today's bucket out loud: time + client name per visit.
// Answers from the App Group snapshot only — no network, no Firebase.
// This file is compiled only on macOS/Xcode.

import AppIntents

@available(iOS 16.0, *)
struct TodayScheduleIntent: AppIntent {
    static var title: LocalizedStringResource = "Today's schedule"
    static var description = IntentDescription(
        "Reads out today's appointments.")

    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy =
        .alwaysAllowed

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = ScheduleSnapshot.load() else {
            return .result(dialog: IntentDialog(
                stringLiteral: SiriStrings.noData))
        }
        guard let bucket = snapshot.today else {
            return .result(dialog: IntentDialog(stringLiteral: SiriStrings.noData))
        }
        let appointments = bucket.appointments
        guard !appointments.isEmpty else {
            return .result(dialog: IntentDialog(
                stringLiteral: bucket.isPartial ? SiriStrings.partialSchedule
                    : SiriStrings.emptyDay(admin: snapshot.isAdmin)))
        }
        let intro = SiriStrings.scheduleIntro(
            appointments.count, admin: snapshot.isAdmin)
        let lines = appointments.map(SiriStrings.scheduleLine)
        let tail = bucket.isPartial ? [SiriStrings.partialSchedule] : []
        let spoken = ([intro] + lines + tail).joined(separator: " ")
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }
}
