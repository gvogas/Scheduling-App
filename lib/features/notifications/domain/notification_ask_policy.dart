import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart'
    show shouldRegisterPush;

/// Whether an account may get the notifications page; the OS status and the
/// once-per-device flag are checked by the gate, not here.
bool isNotificationAskDue({required EmployeeRecord? me}) =>
    me != null &&
    me.uid.isNotEmpty &&
    !me.isTestAccount &&
    shouldRegisterPush(role: me.role, status: me.status, signedIn: true);
