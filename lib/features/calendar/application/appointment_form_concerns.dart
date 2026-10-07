import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart'
    show immutable, protected;

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/domain/policies/appointment_form_validator.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_status.dart';
import 'package:scheduling/features/clients/domain/models/client_search_window.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';
import 'package:scheduling/features/clients/domain/policies/phone_query_policy.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

/// Shared appointment-form fields read through this interface by [AppointmentFormConcerns].
abstract interface class AppointmentFormFields {
  ClientRecord? get selectedClient;
  List<ClientRecord> get clientResults;
  bool get isSearchingClient;
  ClientSearchStatus get clientSearchStatus;
  bool get useCustomAddress;
  List<EmployeeRecord> get selectedEmployees;
  Map<String, AppointmentFormError> get errors;
}

/// One form state change, applied through each controller's adapter. A null
/// field just means that part of the state is unchanged.
@immutable
class AppointmentFormUpdate {
  const AppointmentFormUpdate({
    this.clientResults,
    this.isSearchingClient,
    this.clientSearchStatus,
    this.selectedClient,
    this.clearSelectedClient = false,
    this.useCustomAddress,
    this.selectedEmployees,
    this.errors,
    this.pendingImages,
  });

  final List<ClientRecord>? clientResults;
  final bool? isSearchingClient;
  final ClientSearchStatus? clientSearchStatus;

  /// Non-null when the user picked a client from the search results.
  final ClientRecord? selectedClient;

  /// True when the user explicitly removed the selected client.
  final bool clearSelectedClient;

  final bool? useCustomAddress;
  final List<EmployeeRecord>? selectedEmployees;
  final Map<String, AppointmentFormError>? errors;

  /// Locally picked, not-yet-uploaded photos.
  final List<File>? pendingImages;
}

/// Shared form behavior for searching, selecting, toggling, picking, and
/// clearing. Each controller adapts it to its own state.
mixin AppointmentFormConcerns<StateT extends AppointmentFormFields>
    on Notifier<StateT> {
  static const int maxImagesPerAppointment = 10;

  /// Adapter over the concrete state's `copyWith` for the shared fields.
  @protected
  StateT applyFormUpdate(StateT current, AppointmentFormUpdate update);

  /// Photos already attached to this form, counted against the cap.
  @protected
  int get usedImageCount;

  /// The locally picked, not-yet-uploaded photos.
  @protected
  List<File> get pendingImages;

  void _apply(AppointmentFormUpdate update) =>
      state = applyFormUpdate(state, update);

  /// Request id to prevent stale reads from overwriting fresh results.
  int _searchRequestId = 0;

  /// The last complete answer, kept so extra digits filter it instead of
  /// spending another round trip.
  ClientSearchWindow _clientWindow = ClientSearchWindow.empty;

  /// Clear the results and the narrowing window together. Both halves are the
  /// invariant: a reset that bumps the request id without dropping the window
  /// lets a stale in-flight answer be narrowed onto the new query.
  void _resetSearch(
    ClientQueryMode mode, {
    int digitsTyped = 0,
    bool failed = false,
  }) {
    _searchRequestId++;
    _clientWindow = ClientSearchWindow.empty;
    _apply(
      AppointmentFormUpdate(
        clientResults: const [],
        isSearchingClient: false,
        clientSearchStatus: ClientSearchStatus(
          mode: mode,
          digitsTyped: digitsTyped,
          failed: failed,
        ),
      ),
    );
  }

  Future<void> searchClients(String query) async {
    final trimmed = query.trim();
    final isPhone = PhoneQueryPolicy.isPhoneQuery(trimmed);
    final digits = PhoneQueryPolicy.canonicalDigits(trimmed);
    final mode = isPhone ? ClientQueryMode.phone : ClientQueryMode.text;

    if (trimmed.isEmpty ||
        (!isPhone && !ClientSearchPolicy.shouldSearch(trimmed))) {
      _resetSearch(mode);
      return;
    }

    // Too few digits to be selective: `514` matches the roster twice over and
    // costs 200 document reads to prove it. Hold, and say so.
    if (isPhone && digits.length < PhoneQueryPolicy.minPhoneDigits) {
      _resetSearch(mode, digitsTyped: digits.length);
      return;
    }

    // The candidate set only shrinks as digits land, so a complete previous
    // answer can be filtered instead of asked again.
    if (isPhone && _clientWindow.canNarrowTo(digits)) {
      _searchRequestId++;
      _clientWindow = _clientWindow.narrowTo(digits);
      _apply(
        AppointmentFormUpdate(
          clientResults: _clientWindow.results,
          isSearchingClient: false,
          clientSearchStatus: ClientSearchStatus(
            mode: mode,
            digitsTyped: digits.length,
            answeredRung: PhoneRung.canonical,
          ),
        ),
      );
      return;
    }

    // Resolve these before the await so they survive the sheet being dismissed (Riverpod 3).
    final logger = ref.read(loggerProvider);
    final clientsRepo = ref.read(clientsRepositoryProvider);
    final requestId = ++_searchRequestId;

    // Drop the previous rows NOW. Leaving them under the spinner is the only
    // way to attach a client from a half-typed query without noticing.
    _apply(
      AppointmentFormUpdate(
        clientResults: const [],
        isSearchingClient: true,
        clientSearchStatus: ClientSearchStatus(
          mode: mode,
          digitsTyped: digits.length,
        ),
      ),
    );

    final rungs = isPhone
        ? PhoneQueryPolicy.ladder(trimmed)
        : [(rung: PhoneRung.canonical, digits: trimmed)];

    try {
      for (final rung in rungs) {
        final results = await clientsRepo.searchClients(rung.digits);
        if (!ref.mounted || requestId != _searchRequestId) return;
        if (results.isEmpty && rung != rungs.last) continue;

        _clientWindow = isPhone && rung.rung == PhoneRung.canonical
            ? ClientSearchWindow(
                digits: digits,
                results: results,
                truncated:
                    results.length >= ClientSearchPolicy.resultDisplayLimit,
              )
            : ClientSearchWindow.empty;

        _apply(
          AppointmentFormUpdate(
            clientResults: results,
            isSearchingClient: false,
            clientSearchStatus: ClientSearchStatus(
              mode: mode,
              digitsTyped: digits.length,
              answeredRung: results.isEmpty ? null : rung.rung,
            ),
          ),
        );
        if (results.isNotEmpty) return;
      }
    } catch (e, st) {
      logger.warn('CLI-SEARCH appointment form searchClients failed', e, st);
      if (!ref.mounted || requestId != _searchRequestId) return;
      // A failure that renders as "no clients found" is how a duplicate gets
      // created for a client who is already on file.
      _resetSearch(mode, digitsTyped: digits.length, failed: true);
    }
  }

  void selectClient(ClientRecord client) {
    _apply(
      AppointmentFormUpdate(
        selectedClient: client,
        clientResults: const [],
        useCustomAddress:
            client.noFixedAddress || client.address.trim().isEmpty,
        errors: withoutKey(state.errors, 'client'),
      ),
    );
  }

  void clearClient() {
    _clientWindow = ClientSearchWindow.empty;
    _apply(
      const AppointmentFormUpdate(
        clearSelectedClient: true,
        clientResults: [],
        useCustomAddress: false,
      ),
    );
  }

  void setUseCustomAddress({required bool value}) {
    _apply(AppointmentFormUpdate(useCustomAddress: value));
  }

  void toggleEmployee(EmployeeRecord employee) {
    final next = [...state.selectedEmployees];
    final idx = next.indexWhere((e) => e.id == employee.id);
    if (idx >= 0) {
      next.removeAt(idx);
    } else {
      next.add(employee);
    }
    _apply(
      AppointmentFormUpdate(
        selectedEmployees: next,
        errors: next.isEmpty
            ? state.errors
            : withoutKey(state.errors, 'employees'),
      ),
    );
  }

  /// How many more photos this form will accept. The notice a trimmed pick
  /// raises names THIS, not the total cap — "only 10 more can be added" at the
  /// moment none can is worse than saying nothing.
  int get remainingImageSlots => (maxImagesPerAppointment - usedImageCount)
      .clamp(0, maxImagesPerAppointment);

  /// Adds what fits and returns how many were DROPPED, so the caller can say
  /// so. Returning nothing made a full job's Add-photos button a silent no-op.
  int addImages(List<File> files) {
    final remaining = remainingImageSlots;
    if (remaining <= 0) return files.length;
    final accepted = files.take(remaining).toList();
    _apply(
      AppointmentFormUpdate(pendingImages: [...pendingImages, ...accepted]),
    );
    return files.length - accepted.length;
  }

  /// Drops the pending photo at [index] (exposed as removeImage/removeNewImage).
  @protected
  void removePendingImageAt(int index) {
    final next = [...pendingImages]..removeAt(index);
    _apply(AppointmentFormUpdate(pendingImages: next));
  }
}
