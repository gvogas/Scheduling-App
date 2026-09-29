"use strict";

/**
 * @fileoverview Travel-time "leave now" logic for the reminder sweep: pure
 * helpers plus an orchestrator, with injected
 * `{db, messaging, fetchImpl, apiKey, now, logger}` deps so jest can drive it
 * with mocks, mirroring notification_utils.js.
 *
 * For each employee/candidate-appointment pair, we decide an origin in this
 * order: an intervening appointment's address first (they'll depart from
 * that job), then a fresh background-GPS presence doc (updatedAt <= 25 min),
 * then a recently-ended previous appointment's address (<= 4 h, not
 * cancelled), and finally null — which falls back to the fixed 30-min
 * reminder with the plain reminder text.
 *
 * @module travel_utils
 */

const {
  buildNotificationMessage,
  deliverRecipientOnce,
  toMillis,
  nowMillis,
  toIdList,
  TIMED_RECIPIENT_ROLES,
} = require("./notification_utils");
const {
  startLiveActivity,
  updateLiveActivity,
  endLiveActivity,
} = require("./live_activity_dispatch");
const {liveActivityCtx} = require("./live_activity_utils");
const {recordOf} = require("./notification_policy");
const {scanAppointmentWindow} = require("./appointment_scan");
const {dayCountOf} = require("./day_slice_utils");
const {isTerminalStatus} = require("./time_utils");
const {
  MINUTE_MS,
  MAX_BOOKING_MS,
  TRAVEL_WINDOW_MS,
  TRAVEL_SWEEP_MAX,
  CONTEXT_QUERY_MAX,
  PREV_APPOINTMENT_LOOKBACK_HOURS,
  ON_SITE_FLIP_CHUNK,
  PENDING_STATUSES,
  address: _address,
  pruneEstimates,
  readEstimate,
  canDeferRoutes,
  decideOrigin,
  selectTravelCandidates,
  computeLeadMinutes,
  isDue,
  buildRoutesRequestBody,
  parseRoutesDurationSeconds,
} = require("./travel_policy");
const {
  listCardsDueForOnSite,
  clearCardMarker,
} = require("./live_activity_registry");

const _estimateCache = new Map();

/**
 * Calls Routes API computeRoutes and returns drive seconds, or null on ANY
 * failure — never throws (same error discipline as places.js). `fetchImpl`
 * is injected for jest.
 * @param {{fetchImpl: !Function, apiKey: string, origin: !Object,
 *   destinationAddress: string, now: (Date|number), logger: ?Object}} args
 * @return {!Promise<?number>}
 */
async function computeTravelSeconds({fetchImpl, apiKey, origin,
  destinationAddress, now, logger}) {
  // Routes rejects departure times in the past; nudge just ahead of now.
  const departureTimeIso =
      new Date(nowMillis(now) + 60 * 1000).toISOString();
  const body = buildRoutesRequestBody(
      {origin, destinationAddress, departureTimeIso});
  let response;
  try {
    response = await fetchImpl(
        "https://routes.googleapis.com/directions/v2:computeRoutes",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Goog-Api-Key": apiKey,
            "X-Goog-FieldMask": "routes.duration",
          },
          body: JSON.stringify(body),
        },
    );
  } catch (err) {
    if (logger) {
      logger.warn("travel: routes transport error", {err: err.message});
    }
    return null;
  }
  if (!response.ok) {
    // Log status only — the request carries staff GPS/address data and
    // Google's INVALID_ARGUMENT echoes the offending field back (same reason
    // placesReverseGeocode sets logResponsePreview: false).
    if (logger) {
      logger.warn("travel: routes upstream non-200", {
        status: response.status,
      });
    }
    return null;
  }
  let data;
  try {
    data = await response.json();
  } catch (err) {
    if (logger) {
      logger.warn("travel: invalid JSON in 200 response", {err: err.message});
    }
    return null;
  }
  return parseRoutesDurationSeconds(data);
}

/**
 * Ledger doc id — same `${id}_${startMs}_${employeeDocId}` shape as the
 * push plan's reminderLedgerId, so claims made before the travel upgrade
 * still get honored and the deploy doesn't cause double reminders.
 * @param {string} appointmentId
 * @param {number} startTimeMillis
 * @param {string} employeeDocId
 * @return {string}
 */
function travelReminderLedgerId(appointmentId, startTimeMillis,
    employeeDocId) {
  return `${appointmentId}_${startTimeMillis}_${employeeDocId}`;
}

/**
 * Resolves ONE (candidate, assignee) pair: ledger short-circuit, then
 * decideOrigin, then Routes (deferred when a recent estimate already proves
 * it isn't due), then the due-check, then claim/send/release, then an
 * optional Live Activity start.
 *
 * The Live Activity start hangs off `deliverRecipientOnce`'s claim, so a
 * racing collision can't double-fire a card. Every failure path degrades to
 * the fixed 30-minute `reminder` kind.
 * @param {!Object} deps
 * @param {!Object} args
 * @return {!Promise<{reminded: number, started: number}>}
 */
async function resolveReminderForAssignee(deps, args) {
  const {db, fetchImpl, apiKey, logger} = deps;
  const {candidate: c, employeeDocId, startMs, nowDate, nowMs,
    presence, employeeAppointments, estimates, cache} = args;
  // Absent means ON, so an omitted arg (older call site, failed read) keeps
  // the departure alert rather than silently dropping it.
  const wantsAlerts = args.wantsAlerts !== false;
  const none = {reminded: 0, started: 0};

  const ledgerId = travelReminderLedgerId(
      String(c.id), startMs, employeeDocId);
  // Cheap pre-check before any Routes spend — the atomic create() inside
  // deliverRecipientOnce is still the real exactly-once guard.
  const existing = await db
      .collection("appointmentReminders").doc(ledgerId).get();
  if (existing && existing.exists) return none;

  // An opted-out assignee degrades to the fixed 30-minute reminder rather than
  // losing the notification — the same fallback a missing origin or a Routes
  // failure already takes.
  //
  // THE FLAG MUST BE READ HERE, not just where `kind` is chosen below. The
  // lead time is derived from `travelSeconds`, so gating only the kind still
  // fired the generic "Upcoming job" push at the TRAVEL-derived instant (up to
  // MAX_LEAD_MINUTES early on a long drive) instead of at the documented 30
  // minutes — and still paid Google Routes for an estimate nobody asked for.
  let travelSeconds = null;
  if (wantsAlerts) {
    const origin = decideOrigin({
      presence,
      employeeAppointments,
      candidate: c,
      now: nowDate,
    });
    const destinationAddress = _address(c);
    if (origin && destinationAddress !== "") {
      // A recent estimate that leaves this pair well short of its leave
      // instant defers the (billable) Routes call to a later sweep.
      const key = `${c.id}|${employeeDocId}`;
      const cached = readEstimate(estimates, key, nowMs);
      if (canDeferRoutes({
        seconds: cached, startTimeMillis: startMs, nowMillis: nowMs,
      })) {
        return none;
      }
      travelSeconds = await computeTravelSeconds({
        fetchImpl,
        apiKey,
        origin,
        destinationAddress,
        now: nowDate,
        logger,
      });
      if (travelSeconds != null) {
        estimates.set(key, {seconds: travelSeconds, atMs: nowMs});
      }
    }
  }
  const leadMinutes = computeLeadMinutes(travelSeconds);
  if (!isDue({startTimeMillis: startMs, leadMinutes, nowMillis: nowMs})) {
    return none;
  }
  // `travelSeconds` is already null for an opted-out assignee, by the guard
  // above — this line reads the consequence, never the flag.
  const kind = travelSeconds == null ? "reminder" : "leaveNow";
  const ctx = {
    clientName: c.clientName,
    // A personal job has no client, so the message names it by title —
    // same fallback `_contextFor` uses for the change-driven pushes.
    title: c.title,
    startTime: c.startTime,
    endTime: c.endTime,
    address: c.address,
    travelMinutes: travelSeconds == null ?
        null : Math.ceil(travelSeconds / 60),
  };
  const delivered = await deliverRecipientOnce(deps, {
    collection: "appointmentReminders",
    ledgerId,
    appointmentId: String(c.id),
    employeeDocId,
    kind,
    buildMsg: (locale) => buildNotificationMessage(kind, ctx, locale),
    nowDate,
    label: "reminder",
    roles: TIMED_RECIPIENT_ROLES,
    cache,
  });
  let started = 0;
  // Live Activities deliberately skip multi-day jobs: the card carries the
  // run's `endTime`, and the on-site flip renders that as a live countdown —
  // so a five-day run parks a five-day countdown on the Lock Screen. The
  // leaveNow push itself still goes out; only the card is withheld.
  // `dayCountOf` is last in the chain on purpose: it resolves a window through
  // `Intl`, and every reminder-only or undelivered candidate would otherwise
  // pay for a value it discards.
  if (kind === "leaveNow" && delivered > 0 && dayCountOf(c) <= 1) {
    // Best-effort — a Live Activity failure must not change `reminded` or
    // abort the sweep. No card just leaves the plain leaveNow push
    // unchanged.
    started = await startLiveActivity(deps, {
      appointmentId: String(c.id),
      employeeDocId,
      // Through the one ctx owner, NOT a spread of the push-message ctx
      // above: that one carries `address` raw, so seeding the card this way
      // was the only path that could hand it an untrimmed/undefined address
      // while every update trimmed.
      ctx: {
        ...liveActivityCtx(c, {
          leaveAt: new Date(startMs - leadMinutes * MINUTE_MS),
          travelMinutes: ctx.travelMinutes,
        }),
        // Persisted on the card marker so a later reschedule can rebuild
        // `leaveAt` off the new start instead of mislabelling the job's own
        // start time as the departure time.
        leadMinutes,
      },
      nowDate,
    });
  }
  return {reminded: delivered, started};
}

/**
 * The travel-aware reminder sweep — one notification per (appointment,
 * employee) pair, replacing the fixed 30-min runReminderSweep. Any pair
 * failure is caught and logged without stopping the rest of the sweep.
 * Injectable deps `{db, messaging, fetchImpl, apiKey, now, logger}`.
 * @param {!Object} deps
 * @return {!Promise<{reminded: number}>}
 */
async function runTravelAwareReminderSweep(deps) {
  // fetchImpl/apiKey are consumed by resolveReminderForAssignee off `deps`.
  const {db, now, logger} = deps;
  const nowDate = now || new Date();
  const nowMs = nowMillis(nowDate);
  const windowEnd = new Date(nowMs + TRAVEL_WINDOW_MS);
  const candidates = selectTravelCandidates(
      await scanAppointmentWindow(db, {
        // Deliberately narrower than the other two sweeps' OPEN_STATUSES.
        statuses: PENDING_STATUSES,
        field: "startTime",
        lo: nowDate,
        loOp: ">",
        hi: windowEnd,
        hiOp: "<=",
        // ASCENDING here, unlike its two siblings: the window is entirely in
        // the FUTURE, so the cap should keep the departures happening soonest.
        descending: false,
        cap: TRAVEL_SWEEP_MAX,
        logger,
        label: "runTravelAwareReminderSweep",
        consequence: "latest departures deferred to a later run",
      }),
      nowDate,
  );
  // The flip pass must run even with no upcoming candidates. A job stops
  // being a candidate the moment it starts, so without this, the sweep
  // right after a tech begins their only job would never flip that card to
  // `onSite`.
  if (candidates.length === 0) {
    return {
      reminded: 0,
      liveActivitiesStarted: 0,
      liveActivitiesFlipped: await runOnSiteFlipPass(deps),
    };
  }

  // Per-sweep batching: presence docs in one getAll, and ONE context query
  // per distinct employee, reused across all of that employee's candidates.
  const employeeIds = [...new Set(
      candidates.flatMap((c) => toIdList(c.employeeIds)))];
  // Declared before the prefs read so that read can SEED it: the prefs pass
  // fetches each candidate's `users` doc, and `sendToEmployee` needs the very
  // same doc later in this sweep — it used to read it a second time.
  const cache = new Map();
  const [presenceByEmployee, contextByEmployee, travelPrefsByEmployee] =
    await Promise.all([
      loadPresenceByEmployee(deps, employeeIds),
      loadContextByEmployee(deps, employeeIds, nowMs),
      loadTravelPrefsByEmployee(deps, employeeIds, cache),
    ]);

  let reminded = 0;
  let started = 0;
  // Warm-instance memo, injectable so tests get a clean map per run.
  const estimates = deps.estimateCache || _estimateCache;
  pruneEstimates(estimates, nowMs);
  // Each (job, assignee) pair is an independent chain — a ledger get(), maybe
  // a Routes round trip, then delivery — so they run concurrently, the same
  // shape runOverduePromptSweep and runDailyDigest already use. Serialising
  // them only added wall-clock: at ~200 pairs the sweep approached its 120 s
  // budget, and a sweep killed under `maxInstances: 1` slips its reminders to
  // the next run, i.e. a LATE "time to leave" push — the one failure this
  // feature cannot absorb. The shared `cache`/`estimates` Maps are safe for
  // the reason documented on the overdue sweep: JS is single-threaded, so the
  // worst case is a duplicated read when two pairs miss simultaneously.
  const pairs = [];
  for (const c of candidates) {
    const startMs = toMillis(c.startTime);
    if (startMs == null) continue;
    for (const employeeDocId of toIdList(c.employeeIds)) {
      pairs.push({c, startMs, employeeDocId});
    }
  }
  const outcomes = await Promise.all(pairs.map(
      async ({c, startMs, employeeDocId}) => {
        try {
          return await resolveReminderForAssignee(deps, {
            candidate: c,
            employeeDocId,
            startMs,
            nowDate,
            nowMs,
            presence: presenceByEmployee.get(employeeDocId) || null,
            employeeAppointments: contextByEmployee.get(employeeDocId) || [],
            // Absent means ON — see wantsTravelAlerts.
            wantsAlerts: travelPrefsByEmployee.get(employeeDocId) !== false,
            estimates,
            cache,
          });
        } catch (err) {
          // One failing pair must not stop the sweep.
          if (logger) {
            logger.warn("travel: pair failed", {id: c.id, employeeDocId, err});
          }
          return {reminded: 0, started: 0};
        }
      }));
  for (const outcome of outcomes) {
    reminded += outcome.reminded;
    started += outcome.started;
  }
  const flipped = await runOnSiteFlipPass(deps);
  return {reminded, liveActivitiesStarted: started, liveActivitiesFlipped:
    flipped};
}

/**
 * Every candidate assignee's latest presence fix, in ONE `getAll`.
 *
 * A failure here is not fatal to the sweep: with no presence, `decideOrigin`
 * simply demotes to the address chain, and past that to the fixed 30-minute
 * reminder — the degradation this whole feature is built around.
 *
 * @param {!Object} deps `{db, logger}`.
 * @param {!Array<string>} employeeIds Distinct assignee doc ids.
 * @return {!Promise<!Map<string, ?Object>>} keyed by employee doc id.
 */
async function loadPresenceByEmployee(deps, employeeIds) {
  const {db, logger} = deps;
  const presenceByEmployee = new Map();
  if (employeeIds.length === 0) return presenceByEmployee;
  try {
    const refs = employeeIds.map((id) => db
        .collection("users").doc(id)
        .collection("presence").doc("location"));
    const snaps = await db.getAll(...refs);
    snaps.forEach((s, i) => {
      presenceByEmployee.set(
          employeeIds[i], s && s.exists ? (s.data() || null) : null);
    });
  } catch (err) {
    if (logger) logger.warn("travel: presence getAll failed", {err});
  }
  return presenceByEmployee;
}

/**
 * Whether this person still wants the "time to leave" push.
 *
 * **Defaults to ON.** Every users doc written before this field existed has no
 * value, so reading `undefined` as off would silence the whole fleet — and the
 * symptom is a push that does not arrive, which nobody reports. Only an
 * explicit `false` opts out.
 *
 * Scope is deliberately narrow: it gates the ESCALATION to `leaveNow` only.
 * An opted-out assignee still gets the fixed 30-minute `reminder`, the same
 * degradation every other travel failure already takes — the toggle turns off
 * traffic-aware departure alerts, not their reminders.
 *
 * @param {?Object} user The users doc data, or null when it could not be read.
 * @return {boolean}
 */
function wantsTravelAlerts(user) {
  return !user || user.travelAlertsEnabled !== false;
}

/**
 * Each candidate assignee's `travelAlertsEnabled` preference.
 *
 * One read per distinct assignee per sweep, alongside the presence and context
 * loads above — the flag has to be known BEFORE the kind is chosen, which is
 * before `sendToEmployee` needs the same doc. The candidate set is the jobs
 * inside the 90-minute window, so this is a handful of reads every 5 minutes,
 * not a roster scan.
 *
 * A failed read yields no entry, and `wantsTravelAlerts(null)` is true — the
 * safe direction, since a transient Firestore error must not silence a
 * departure alert.
 *
 * @param {!Object} deps `{db, logger}`.
 * @param {!Array<string>} employeeIds Distinct assignee doc ids.
 * @param {!Map=} cache The sweep's `sendToEmployee` cache, seeded with each
 *   users doc this pass reads so the delivery pass doesn't read it again.
 *   Tokens are left `null` (= not fetched) rather than `[]`.
 * @return {!Promise<!Map<string, boolean>>} keyed by employee doc id.
 */
async function loadTravelPrefsByEmployee(deps, employeeIds, cache) {
  const {db, logger} = deps;
  const prefs = new Map();
  if (employeeIds.length === 0) return prefs;
  await Promise.all(employeeIds.map(async (id) => {
    try {
      const snap = await db.collection("users").doc(id).get();
      const user = snap && snap.exists ? (snap.data() || null) : null;
      prefs.set(id, wantsTravelAlerts(user));
      // Seed the sweep's send cache with the doc we just paid for.
      // `sendToEmployee` fetches `fcmTokens` lazily, so a null there means
      // "not read yet" rather than "no tokens".
      if (cache && !cache.has(id)) cache.set(id, {user, tokenDocs: null});
    } catch (err) {
      if (logger) logger.warn("travel: prefs read failed", {id, err});
    }
  }));
  return prefs;
}

/**
 * Each candidate assignee's surrounding appointments, for `decideOrigin`.
 *
 * One query per distinct employee, issued concurrently — they are independent,
 * and one throwing falls back to `[]` for that person rather than failing the
 * others.
 *
 * @param {!Object} deps `{db, logger}`.
 * @param {!Array<string>} employeeIds Distinct assignee doc ids.
 * @param {number} nowMs Sweep clock in millis.
 * @return {!Promise<!Map<string, !Array<!Object>>>} keyed by employee doc id.
 */
async function loadContextByEmployee(deps, employeeIds, nowMs) {
  const {db, logger} = deps;
  const contextByEmployee = new Map();
  const lookbackStart = new Date(
      nowMs - PREV_APPOINTMENT_LOOKBACK_HOURS * 60 * MINUTE_MS);
  const contextEnd = new Date(nowMs + TRAVEL_WINDOW_MS + MAX_BOOKING_MS);
  await Promise.all(employeeIds.map(async (employeeDocId) => {
    try {
      // Upper-bounded on the same field. Without that bound the query would
      // match every future appointment, and a pre-booked series would
      // saturate CONTEXT_QUERY_MAX. The bound clears the window by
      // MAX_BOOKING_MS since an intervening job can run a full day past it.
      const ctxSnap = await db
          .collection("appointments")
          .where("employeeIds", "array-contains", employeeDocId)
          .where("endTime", ">", lookbackStart)
          .where("endTime", "<=", contextEnd)
          .orderBy("endTime")
          .limit(CONTEXT_QUERY_MAX)
          .get();
      // At the cap the query is a PREFIX ordered by endTime ASC, so the
      // furthest-out docs are dropped — which is exactly where a multi-day run
      // sorts. decideOrigin's near-term prongs are unaffected, but the
      // intervening-job prong can silently stop seeing a long run. Warn rather
      // than truncate in silence, like runOverduePromptSweep does.
      if (logger && ctxSnap && ctxSnap.size === CONTEXT_QUERY_MAX) {
        logger.warn("travel: context query hit the cap", {
          employeeDocId,
          cap: CONTEXT_QUERY_MAX,
        });
      }
      contextByEmployee.set(
          employeeDocId,
          ((ctxSnap && ctxSnap.docs) || []).map(recordOf));
    } catch (err) {
      if (logger) {
        logger.warn("travel: context query failed", {employeeDocId, err});
      }
      contextByEmployee.set(employeeDocId, []);
    }
  }));
  return contextByEmployee;
}

/**
 * Backstop that pushes one update per started job to flip its Lock Screen
 * card from `travel` to `onSite`, riding the existing 5-minute sweep with no
 * new scheduler.
 *
 * Driven off the card markers, not an appointments query, since they're the
 * only record of which techs have a card. Best-effort — failures are
 * swallowed without affecting the reminder sweep.
 * @param {!Object} deps `{db, now, logger, apnsAuth}`.
 * @return {!Promise<number>} Cards updated.
 */
async function runOnSiteFlipPass(deps) {
  const {db, now, logger} = deps;
  const nowDate = now || new Date();
  const markers = await listCardsDueForOnSite(deps);
  // Concurrent, like the candidate loop above and for the same reason: each
  // marker is an independent chain of a `doc.get()`, a token query and a
  // direct APNs push, ~300 ms of round-trips that share nothing. Serialised,
  // `PRUNE_MAX` (400) markers is up to ~120 s of the 420 s budget this
  // function shares with the billable travel half — every 5 minutes.
  //
  // CHUNKED rather than one flat `Promise.all`, matching `PRUNE_CHUNK` in
  // `live_activity_registry.js`: this list is bounded by that same 400, and
  // each entry here is heavier than a delete — a read, a query and an APNs
  // push apiece, so a flat fan-out is ~1200 concurrent requests out of one
  // invocation. The per-marker try/catch stays either way: one failing card
  // must not stop the pass.
  const flip = async (marker) => {
    try {
      const snap = await db
          .collection("appointments").doc(marker.appointmentId).get();
      const record = snap && snap.exists ? (snap.data() || {}) : null;
      // A deleted/terminal job has to call endLiveActivity, not just drop
      // the marker, since the Lock Screen card outlives the Firestore doc.
      // We also clear the marker here so this doesn't retry every sweep.
      if (!record ||
          isTerminalStatus(record.status)) {
        await endLiveActivity(deps, {
          appointmentId: String(marker.appointmentId),
          employeeDocId: marker.employeeDocId,
          ctx: liveActivityCtx(record),
          nowDate,
        });
        await clearCardMarker(deps, {employeeDocId: marker.employeeDocId});
        return 0;
      }
      return await updateLiveActivity(deps, {
        appointmentId: String(marker.appointmentId),
        employeeDocId: marker.employeeDocId,
        ctx: liveActivityCtx(record),
        nowDate,
      });
    } catch (err) {
      // One failing card must not stop the pass.
      if (logger) {
        logger.warn("liveActivity: on-site flip failed",
            {employeeDocId: marker.employeeDocId, err});
      }
      return 0;
    }
  };

  let flipped = 0;
  for (let i = 0; i < markers.length; i += ON_SITE_FLIP_CHUNK) {
    const done = await Promise.all(
        markers.slice(i, i + ON_SITE_FLIP_CHUNK).map(flip));
    flipped += done.reduce((sum, n) => sum + n, 0);
  }
  return flipped;
}

module.exports = {
  decideOrigin,
  selectTravelCandidates,
  computeLeadMinutes,
  isDue,
  buildRoutesRequestBody,
  parseRoutesDurationSeconds,
  computeTravelSeconds,
  travelReminderLedgerId,
  wantsTravelAlerts,
  runTravelAwareReminderSweep,
  runOnSiteFlipPass,
};
