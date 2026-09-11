/// The `wave.syncState` vocabulary, written only by Cloud Functions.
///
/// `blocked` is the fourth state (2026-09-10): the customer contract refused
/// the client, so it never became a queued job. It is deliberately separate
/// from `error` — the remedy differs (edit the client vs. retry or
/// investigate), and it never enters the outbox, so it is absent from the
/// pending and failed counters Settings shows.
const String kWaveSyncStateSynced = 'synced';
const String kWaveSyncStatePending = 'pending';
const String kWaveSyncStateBlocked = 'blocked';
const String kWaveSyncStateError = 'error';
