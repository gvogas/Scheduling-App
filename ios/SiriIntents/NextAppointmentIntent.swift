// "What's my next appointment in ES Pro?"
//
// Earliest upcoming visit across the whole 7-day window that hasn't been marked
// done — so an empty rest-of-today still answers with tomorrow's first job.
// Answers from the App Group snapshot only — no network, no Firebase.
// This file is compiled only on macOS/Xcode.

import AppIntents

@available(iOS 16.0, *)
struct NextAppointmentIntent: AppIntent {
    static var title: LocalizedStringResource = "Next appointment"
    static var description = IntentDescription(
        "Says when and where the next appointment is.")

    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy =
        .alwaysAllowed

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = ScheduleSnapshot.load() else {
            return .result(dialog: IntentDialog(
                stringLiteral: SiriStrings.noData))
        }
        guard let next = snapshot.nextAppointment() else {
            return .result(dialog: IntentDialog(
                stringLiteral: snapshot.days.contains(where: \.isPartial)
                    ? SiriStrings.partialSchedule : SiriStrings.noNext))
        }
        return .result(dialog: IntentDialog(
            stringLiteral: SiriStrings.next(next)))
    }
}
