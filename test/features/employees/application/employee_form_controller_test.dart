import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/employees/application/employee_form_controller.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_failure.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

void main() {
  late _MockEmployeesRepo repo;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbackValue(const EmployeeRecord(id: 'fallback'));
  });

  setUp(() {
    repo = _MockEmployeesRepo();
    container = ProviderContainer(
      overrides: [employeesRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
  });

  EmployeeFormController notifier() =>
      container.read(employeeFormControllerProvider.notifier);

  EmployeeFormActivity activity() =>
      container.read(employeeFormControllerProvider);

  Future<EmployeeSaveOutcome> create() => notifier().createAccount(
    const EmployeeRecord(
      id: '',
      name: 'Alex',
      firstName: 'Alex',
      email: 'alex@test.com',
      phone: '555-0001',
      color: Color(0x0000007B),
      role: 'admin',
      jobTitle: JobTitle.technician,
    ),
  );

  const edited = EmployeeRecord(
    id: 'e1',
    name: 'Alex',
    email: 'alex@test.com',
    phone: '555-0001',
    role: 'admin',
  );

  Future<EmployeeSaveOutcome> update() => notifier().updateEmployee(edited);

  group('reentrancy', () {
    test('a concurrent save returns Busy, not a failure', () async {
      final gate = Completer<NewAccountCredentials>();
      when(
        () => repo.createEmployeeAccount(
          name: any(named: 'name'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          email: any(named: 'email'),
          phone: any(named: 'phone'),
          colorValue: any(named: 'colorValue'),
          jobTitle: any(named: 'jobTitle'),
        ),
      ).thenAnswer((_) => gate.future);

      final first = create();
      // Second tap lands while the first write is still in flight.
      final second = await create();

      // Busy, NOT EmployeeSaveFailed — a SocketException here is classified by
      // TYPE as "offline" and rendered a false offline notice while online.
      expect(second, isA<EmployeeSaveBusy>());

      gate.complete(
        const NewAccountCredentials(
          email: 'alex@test.com',
          password: 'Welcome123!',
        ),
      );
      expect(await first, isA<EmployeeAccountCreated>());
      // Only the one write reached the repository.
      verify(
        () => repo.createEmployeeAccount(
          name: any(named: 'name'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          email: any(named: 'email'),
          phone: any(named: 'phone'),
          colorValue: any(named: 'colorValue'),
          jobTitle: any(named: 'jobTitle'),
        ),
      ).called(1);
    });

    test(
      'a save for a DIFFERENT employee is not blocked by one in flight',
      () async {
        const credentials = NewAccountCredentials(
          email: 'b@test.com',
          password: 'Welcome123!',
        );
        // A's call hangs on the gate; B's returns straight away, so the only
        // thing that can stall B is the controller's own guard.
        final gate = Completer<NewAccountCredentials>();
        when(
          () => repo.createEmployeeAccount(
            name: any(named: 'name'),
            firstName: any(named: 'firstName'),
            lastName: any(named: 'lastName'),
            email: 'a@test.com',
            phone: any(named: 'phone'),
            colorValue: any(named: 'colorValue'),
            jobTitle: any(named: 'jobTitle'),
          ),
        ).thenAnswer((_) => gate.future);
        when(
          () => repo.createEmployeeAccount(
            name: any(named: 'name'),
            firstName: any(named: 'firstName'),
            lastName: any(named: 'lastName'),
            email: 'b@test.com',
            phone: any(named: 'phone'),
            colorValue: any(named: 'colorValue'),
            jobTitle: any(named: 'jobTitle'),
          ),
        ).thenAnswer((_) async => credentials);

        // Two expanded pending rows, each tapping Reset password.
        final rowA = notifier().createAccount(
          const EmployeeRecord(id: 'a', email: 'a@test.com'),
        );
        final rowB = await notifier()
            .createAccount(const EmployeeRecord(id: 'b', email: 'b@test.com'))
            .timeout(
              const Duration(seconds: 1),
              onTimeout: () => throw StateError('B never resolved'),
            );

        // NOT Busy: the guard is keyed per employee. A global flag dropped this
        // tap silently — no spinner, no notice, nothing written.
        expect(rowB, isA<EmployeeAccountCreated>());
        expect(activity().isSavingId('a'), isTrue);
        expect(activity().isSavingId('b'), isFalse);

        gate.complete(
          const NewAccountCredentials(
            email: 'a@test.com',
            password: 'Welcome123!',
          ),
        );
        expect(await rowA, isA<EmployeeAccountCreated>());
        expect(activity().isSaving, isFalse);
      },
    );

    test(
      'removing one pending account leaves another row actionable',
      () async {
        final gate = Completer<void>();
        when(
          () => repo.deleteEmployeeAccount('a'),
        ).thenAnswer((_) => gate.future);
        when(() => repo.deleteEmployeeAccount('b')).thenAnswer((_) async {});

        final rowA = notifier().deleteAccount('a');
        expect(activity().isDeletingAccountId('a'), isTrue);
        expect(activity().isDeletingAccountId('b'), isFalse);

        expect(await notifier().deleteAccount('b'), isA<AccountDeleted>());

        gate.complete();
        expect(await rowA, isA<AccountDeleted>());
        expect(activity().isDeletingAccount, isFalse);
      },
    );

    test('a concurrent delete for the SAME pending account returns Busy', () async {
      final gate = Completer<void>();
      when(() => repo.deleteEmployeeAccount('a')).thenAnswer((_) => gate.future);

      final first = notifier().deleteAccount('a');
      final second = await notifier().deleteAccount('a');

      expect(second, isA<AccountDeleteBusy>());

      gate.complete();
      expect(await first, isA<AccountDeleted>());
      verify(() => repo.deleteEmployeeAccount('a')).called(1);
    });
  });

  group('createAccount', () {
    test('returns the sign-in credentials on success', () async {
      when(
        () => repo.createEmployeeAccount(
          name: any(named: 'name'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          email: any(named: 'email'),
          phone: any(named: 'phone'),
          colorValue: any(named: 'colorValue'),
          jobTitle: any(named: 'jobTitle'),
        ),
      ).thenAnswer(
        (_) async => const NewAccountCredentials(
          email: 'alex@test.com',
          password: 'Welcome123!',
        ),
      );

      final outcome = await create();

      expect(outcome, isA<EmployeeAccountCreated>());
      expect(
        (outcome as EmployeeAccountCreated).credentials.password,
        'Welcome123!',
      );
      expect(activity().isSaving, isFalse);
    });

    test('recomposes name from first and last before creating the account', () async {
      when(
        () => repo.createEmployeeAccount(
          name: any(named: 'name'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          email: any(named: 'email'),
          phone: any(named: 'phone'),
          colorValue: any(named: 'colorValue'),
          jobTitle: any(named: 'jobTitle'),
        ),
      ).thenAnswer(
        (_) async => const NewAccountCredentials(
          email: 'alex@test.com',
          password: 'Welcome123!',
        ),
      );

      await notifier().createAccount(
        const EmployeeRecord(
          id: '',
          firstName: 'Amy',
          lastName: 'Adams',
          email: 'amy@test.com',
        ),
      );

      verify(
        () => repo.createEmployeeAccount(
          name: 'Amy Adams',
          firstName: 'Amy',
          lastName: 'Adams',
          email: 'amy@test.com',
          phone: '',
          colorValue: any(named: 'colorValue'),
          jobTitle: any(named: 'jobTitle'),
        ),
      ).called(1);
    });

    test('surfaces a taken email as a field-level outcome', () async {
      when(
        () => repo.createEmployeeAccount(
          name: any(named: 'name'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          email: any(named: 'email'),
          phone: any(named: 'phone'),
          colorValue: any(named: 'colorValue'),
          jobTitle: any(named: 'jobTitle'),
        ),
      ).thenThrow(const EmployeesFailureEmailAlreadyExists());

      expect(await create(), isA<EmployeeEmailInUse>());
      expect(activity().isSaving, isFalse);
    });

    test('reports other failures with the original error', () async {
      final boom = Exception('offline');
      when(
        () => repo.createEmployeeAccount(
          name: any(named: 'name'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          email: any(named: 'email'),
          phone: any(named: 'phone'),
          colorValue: any(named: 'colorValue'),
          jobTitle: any(named: 'jobTitle'),
        ),
      ).thenThrow(boom);

      final outcome = await create();

      expect(outcome, isA<EmployeeSaveFailed>());
      expect((outcome as EmployeeSaveFailed).error, boom);
      expect(activity().isSaving, isFalse);
    });
  });

  group('updateEmployee', () {
    test('persists the edit and reports updated', () async {
      when(
        () => repo.updateEmployee(
          docId: any(named: 'docId'),
          employee: any(named: 'employee'),
        ),
      ).thenAnswer((_) async {});

      expect(await update(), isA<EmployeeUpdated>());
      verify(
        () => repo.updateEmployee(docId: 'e1', employee: edited),
      ).called(1);
      expect(activity().isSaving, isFalse);
    });

    test('reports failures with the original error', () async {
      when(
        () => repo.updateEmployee(
          docId: any(named: 'docId'),
          employee: any(named: 'employee'),
        ),
      ).thenThrow(Exception('offline'));

      expect(await update(), isA<EmployeeSaveFailed>());
      expect(activity().isSaving, isFalse);
    });
  });

  group('setEmployeeStatus', () {
    test('a concurrent status toggle returns Busy, not a duplicate write', () async {
      final gate = Completer<void>();
      when(() => repo.deactivateEmployee('e1')).thenAnswer((_) => gate.future);

      final first = notifier().setEmployeeStatus(docId: 'e1', disable: true);
      final second = await notifier().setEmployeeStatus(
        docId: 'e1',
        disable: true,
      );

      expect(second, isA<EmployeeStatusBusy>());

      gate.complete();
      expect(await first, isA<EmployeeStatusChanged>());
      verify(() => repo.deactivateEmployee('e1')).called(1);
      expect(activity().isTogglingStatus, isFalse);
    });

    test('disables via deactivateEmployee', () async {
      when(() => repo.deactivateEmployee(any())).thenAnswer((_) async {});

      final outcome = await notifier().setEmployeeStatus(
        docId: 'e1',
        disable: true,
      );

      expect(outcome, isA<EmployeeStatusChanged>());
      verify(() => repo.deactivateEmployee('e1')).called(1);
      verifyNever(() => repo.reactivateEmployee(any()));
      expect(activity().isTogglingStatus, isFalse);
    });

    test('re-enables via reactivateEmployee', () async {
      when(() => repo.reactivateEmployee(any())).thenAnswer((_) async {});

      final outcome = await notifier().setEmployeeStatus(
        docId: 'e1',
        disable: false,
      );

      expect(outcome, isA<EmployeeStatusChanged>());
      verify(() => repo.reactivateEmployee('e1')).called(1);
    });

    test('reports failures with the original error', () async {
      when(() => repo.deactivateEmployee(any())).thenThrow(Exception('boom'));

      final outcome = await notifier().setEmployeeStatus(
        docId: 'e1',
        disable: true,
      );

      expect(outcome, isA<EmployeeStatusChangeFailed>());
      expect(activity().isTogglingStatus, isFalse);
    });
  });

  group('deleteAccount', () {
    test('reports deleted and clears the busy flag', () async {
      when(() => repo.deleteEmployeeAccount(any())).thenAnswer((_) async {});

      final outcome = await notifier().deleteAccount('doc-1');

      expect(outcome, isA<AccountDeleted>());
      verify(() => repo.deleteEmployeeAccount('doc-1')).called(1);
      expect(activity().isDeletingAccount, isFalse);
    });

    test('a server refusal is a failed outcome carrying the error', () async {
      // Someone finished setup while the admin was looking at the row.
      const refusal = EmployeesFailureAccountNoLongerPending();
      when(() => repo.deleteEmployeeAccount(any())).thenThrow(refusal);

      final outcome = await notifier().deleteAccount('doc-1');

      expect(outcome, isA<AccountDeleteFailed>());
      expect((outcome as AccountDeleteFailed).error, refusal);
      expect(activity().isDeletingAccount, isFalse);
    });

    test('reports other failures with the original error', () async {
      final boom = Exception('offline');
      when(() => repo.deleteEmployeeAccount(any())).thenThrow(boom);

      final outcome = await notifier().deleteAccount('doc-1');

      expect((outcome as AccountDeleteFailed).error, boom);
      expect(activity().isDeletingAccount, isFalse);
    });
  });

  group('resetPassword', () {
    const issued = NewAccountCredentials(
      email: 'alex@test.com',
      password: 'Tmp2pass!wd9',
    );

    test('returns the issued credentials and clears the busy flag', () async {
      when(
        () => repo.resetEmployeePassword('e1'),
      ).thenAnswer((_) async => issued);

      final outcome = await notifier().resetPassword('e1');

      expect(
        outcome,
        isA<PasswordResetIssued>().having(
          (o) => o.credentials,
          'credentials',
          issued,
        ),
      );
      expect(activity().isResettingPassword, isFalse);
    });

    test('a server failure is a Failed outcome carrying the error', () async {
      final error = Exception('boom');
      when(() => repo.resetEmployeePassword('e1')).thenThrow(error);

      final outcome = await notifier().resetPassword('e1');

      expect(
        outcome,
        isA<PasswordResetFailed>().having((o) => o.error, 'error', error),
      );
      expect(activity().isResettingPassword, isFalse);
    });

    test('a second tap while one is in flight is Busy', () async {
      final gate = Completer<NewAccountCredentials>();
      when(
        () => repo.resetEmployeePassword('e1'),
      ).thenAnswer((_) => gate.future);

      final first = notifier().resetPassword('e1');
      expect(activity().isResettingPassword, isTrue);
      expect(await notifier().resetPassword('e1'), isA<PasswordResetBusy>());

      gate.complete(issued);
      expect(await first, isA<PasswordResetIssued>());
      verify(() => repo.resetEmployeePassword('e1')).called(1);
    });
  });
}
