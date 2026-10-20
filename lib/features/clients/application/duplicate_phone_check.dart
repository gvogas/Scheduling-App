import 'package:flutter/widgets.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/utils/debouncer.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

/// Watches the add-client phone field for a number already on file, so a
/// second client (and a second Wave customer) is not created silently.
///
/// Debounced on every change of [phone] — typing and the name→phone lift
/// alike — and settled on demand by [ensureChecked] before Add commits. A
/// failed lookup fails OPEN: a dead callable must not block adding a client.
class DuplicatePhoneCheck extends ChangeNotifier {
  DuplicatePhoneCheck({
    required ClientsRepository repository,
    required AppLogger logger,
    required this.phone,
  }) : _repository = repository,
       _logger = logger,
       _debounce = Debouncer.tagged(
         kSearchDebounce,
         logger: logger,
         tag: 'CLI-SEARCH duplicate phone check failed',
       ) {
    phone.addListener(_onPhoneChanged);
  }

  final ClientsRepository _repository;
  final AppLogger _logger;
  final TextEditingController phone;
  final Debouncer _debounce;

  /// Fewer digits than this is not yet a number anyone could be stored under.
  static const int minDigits = 7;

  /// The client on file with this number, once a lookup has found one.
  ClientRecord? match;

  /// The admin chose "Use anyway" for the current number.
  bool acknowledged = false;

  String _checkedDigits = '';
  Future<void>? _inFlight;

  /// True while a found duplicate is still unanswered.
  bool get blocksSave => match != null && !acknowledged;

  void useAnyway() {
    acknowledged = true;
    notifyListeners();
  }

  /// Runs any lookup still pending for the current number and waits for it.
  Future<void> ensureChecked() async {
    _debounce.cancel();
    final digits = phoneDigits(phone.text);
    if (digits != _checkedDigits) {
      await _lookup(digits);
      return;
    }
    await _inFlight;
  }

  void _onPhoneChanged() {
    final digits = phoneDigits(phone.text);
    if (digits == _checkedDigits) return;
    if (match != null || acknowledged) {
      match = null;
      acknowledged = false;
      notifyListeners();
    }
    _debounce.run(() => _lookup(digits));
  }

  Future<void> _lookup(String digits) {
    final run = _runLookup(digits);
    _inFlight = run;
    return run;
  }

  Future<void> _runLookup(String digits) async {
    if (digits.length < minDigits) {
      _checkedDigits = digits;
      return;
    }
    try {
      final results = await _repository.searchClients(digits);
      // Superseded while the callable ran.
      if (phoneDigits(phone.text) != digits) return;
      _checkedDigits = digits;
      match = results.where((c) => _isExact(c, digits)).firstOrNull;
      acknowledged = false;
      notifyListeners();
    } catch (e, st) {
      _logger.warn('CLI-SEARCH duplicate phone check failed', e, st);
      _checkedDigits = digits;
    }
  }

  // Tier 0 of the shared ranking: the client's OWN number, NANP-folded, so
  // the one owner of that rule stays `relevanceScore` (ADR-0021).
  static bool _isExact(ClientRecord client, String digits) =>
      ClientSearchPolicy.scoreRecord(
        client,
        queryText: ClientSearchPolicy.normalize(digits),
        queryDigits: digits,
      ) ==
      0;

  @override
  void dispose() {
    phone.removeListener(_onPhoneChanged);
    _debounce.dispose();
    super.dispose();
  }
}
