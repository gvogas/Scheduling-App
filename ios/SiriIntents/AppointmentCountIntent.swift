// "How many appointments do I have today in ES Pro?"
//
// Answers from the App Group snapshot only — no network, no Firebase.
// This file is compiled only on macOS/Xcode.

import AppIntents

@available(iOS 16.0, *)
struct AppointmentCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Appointment count today"
    static var description = IntentDescription(
        "Says how many appointments are on today's schedule.")

    // Safe to run from the lock screen, since it's just the caller's own
    // schedule. Write intents (Phase 4) must NOT set this.
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
        if bucket.coverageComplete != true {
            return .result(dialog: IntentDialog(
                stringLiteral: SiriStrings.partialCount(bucket.appointments.count)))
        }
        let count = bucket.totalCount ?? bucket.appointments.count
        return .result(dialog: IntentDialog(
            stringLiteral: SiriStrings.count(count, admin: snapshot.isAdmin)))
    }
}
