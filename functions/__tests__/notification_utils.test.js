"use strict";

/**
 * Unit tests for the push-notification pure helpers and the injectable
 * orchestration (handleAppointmentWrite / runDailyDigest / overdue sweep).
 */

const {
  diffAppointmentForNotifications,
  buildNotificationMessage,
  buildDigestMessage,
  selectOverdueCandidates,
  groupTomorrowsJobsByEmployee,
  tomorrowWindowToronto,
  overduePromptLedgerId,
  isStaleTokenError,
  deliverRecipientOnce,
  handleAppointmentWrite,
  OPEN_STATUSES,
  SERIES_CLAIM_WINDOW_MS,
  TIMED_RECIPIENT_ROLES,
  OVERDUE_LOOKBACK_MS,
} = require("../notification_utils");
const {
  runDailyDigest,
  runOverduePromptSweep,
} = require("../notification_sweeps");

// Noon Toronto (EDT -4) on Wed 2026-07-08.
const NOW = new Date("2026-07-08T16:00:00.000Z");
const HOUR = 60 * 60 * 1000;
const MIN = 60 * 1000;

const future = (ms) => new Date(NOW.getTime() + ms);
const kinds = (evs) => evs.map((e) => `${e.employeeDocId}:${e.kind}`).sort();

describe("diffAppointmentForNotifications", () => {
  test("created assigns every employee", () => {
    const evs = diffAppointmentForNotifications(
        null,
        {employeeIds: ["e1", "e2"], startTime: future(3 * HOUR)},
        NOW,
    );
    expect(kinds(evs)).toEqual(["e1:assigned", "e2:assigned"]);
  });

  test("a pictures-only rewrite emits nothing", () => {
    // Load-bearing for COST, not just correctness. The writer that made it so
    // was `rotateAssignedImageTokens`, which rewrote `pictures[].url` on up to
    // 500 appointments per deactivation; that function was deleted at the
    // CONTRACT step, but `clear-appointment-picture-arrays.js` does the same
    // shape of bulk parent write, and every one of those fires
    // `notifyAppointmentChanges`. The fan-out is only acceptable because each
    // invocation is a genuine no-op: no events here means
    // `handleAppointmentWrite` returns before any Firestore read, so 500
    // writes cost 500 empty invocations rather than 500 recipient lookups and
    // widget-window queries. (The recount trigger is on the images
    // SUBcollection, so it is not fired by these writes at all.) Make the
    // differ sensitive to `pictures` and that stops being true — which is what
    // this pins.
    const base = {
      employeeIds: ["e1"],
      startTime: future(3 * HOUR),
      status: "pending",
    };
    const evs = diffAppointmentForNotifications(
        {...base, pictures: [{url: "old", storagePath: "p"}]},
        {...base, pictures: [{url: "new", storagePath: "p"}]},
        NOW,
        "a1",
    );
    expect(evs).toEqual([]);
  });

  test("created already cancelled emits nothing", () => {
    const evs = diffAppointmentForNotifications(
        null,
        {employeeIds: ["e1"], startTime: future(3 * HOUR), status: "cancelled"},
        NOW,
    );
    expect(evs).toEqual([]);
  });

  test("cancelling a multi-day run mid-flight still tells the crew", () => {
    // The gate is the run's END, not its start. Gating on the start meant a
    // job cancelled on day 4 of 10 pushed nothing and the crew turned up.
    const run = {
      employeeIds: ["e1", "e2"],
      startTime: future(-3 * 24 * HOUR),
      endTime: future(6 * 24 * HOUR),
    };
    const evs = diffAppointmentForNotifications(
        run,
        {...run, status: "cancelled"},
        NOW,
    );
    expect(kinds(evs)).toEqual(["e1:cancelled", "e2:cancelled"]);
  });

  test("deleting a multi-day run mid-flight still tells the crew", () => {
    const evs = diffAppointmentForNotifications(
        {
          employeeIds: ["e1"],
          startTime: future(-3 * 24 * HOUR),
          endTime: future(6 * 24 * HOUR),
        },
        null,
        NOW,
    );
    expect(kinds(evs)).toEqual(["e1:cancelled"]);
  });

  test("a run that has genuinely finished still emits nothing", () => {
    const evs = diffAppointmentForNotifications(
        {
          employeeIds: ["e1"],
          startTime: future(-9 * 24 * HOUR),
          endTime: future(-2 * 24 * HOUR),
        },
        null,
        NOW,
    );
    expect(evs).toEqual([]);
  });

  test("falls back to startTime when the record carries no endTime", () => {
    const evs = diffAppointmentForNotifications(
        {employeeIds: ["e1"], startTime: future(-3 * HOUR)},
        null,
        NOW,
    );
    expect(evs).toEqual([]);
  });

  test("deleted cancels the before employees", () => {
    const evs = diffAppointmentForNotifications(
        {employeeIds: ["e1"], startTime: future(3 * HOUR)},
        null,
        NOW,
    );
    expect(kinds(evs)).toEqual(["e1:cancelled"]);
  });

  test("status -> cancelled cancels the before employees", () => {
    const evs = diffAppointmentForNotifications(
        {employeeIds: ["e1"], startTime: future(3 * HOUR), status: "pending"},
        {employeeIds: ["e1"], startTime: future(3 * HOUR), status: "cancelled"},
        NOW,
    );
    expect(kinds(evs)).toEqual(["e1:cancelled"]);
  });

  test("removed + added, same time", () => {
    const t = future(3 * HOUR);
    const evs = diffAppointmentForNotifications(
        {employeeIds: ["e1", "e2"], startTime: t},
        {employeeIds: ["e2", "e3"], startTime: t},
        NOW,
    );
    // e2 stayed with no time change -> no event.
    expect(kinds(evs)).toEqual(["e1:removed", "e3:assigned"]);
  });

  test("reschedule reschedules the ids that stayed", () => {
    const evs = diffAppointmentForNotifications(
        {employeeIds: ["e1", "e2"], startTime: future(3 * HOUR)},
        {employeeIds: ["e1", "e2"], startTime: future(4 * HOUR)},
        NOW,
    );
    expect(kinds(evs)).toEqual(["e1:rescheduled", "e2:rescheduled"]);
  });

  test("a just-added id on a reschedule is assigned, not rescheduled", () => {
    const evs = diffAppointmentForNotifications(
        {employeeIds: ["e1"], startTime: future(3 * HOUR)},
        {employeeIds: ["e1", "e2"], startTime: future(4 * HOUR)},
        NOW,
    );
    expect(kinds(evs)).toEqual(["e1:rescheduled", "e2:assigned"]);
  });

  test("a pure status change (no cancel) emits nothing", () => {
    const t = future(3 * HOUR);
    const evs = diffAppointmentForNotifications(
        {employeeIds: ["e1"], startTime: t, status: "pending"},
        {employeeIds: ["e1"], startTime: t, status: "done"},
        NOW,
    );
    expect(evs).toEqual([]);
  });

  test("past appointments are skipped", () => {
    const evs = diffAppointmentForNotifications(
        null,
        {employeeIds: ["e1"], startTime: future(-1 * HOUR)},
        NOW,
    );
    expect(evs).toEqual([]);
  });

  test("repeating series: only the anchor sends assigned", () => {
    const after = {
      employeeIds: ["e1"],
      startTime: future(3 * HOUR),
      seriesId: "s1",
      repeat: "six_months",
    };
    // The anchor occurrence (its own id === seriesId) sends one push.
    expect(kinds(diffAppointmentForNotifications(null, after, NOW, "s1")))
        .toEqual(["e1:assigned"]);
    // A pre-booked copy of the same series (id !== seriesId) is suppressed.
    expect(diffAppointmentForNotifications(null, after, NOW, "copy2"))
        .toEqual([]);
  });
});

describe("selectOverdueCandidates", () => {
  const rec = (id, endMs, status) => ({
    id,
    status,
    endTime: future(endMs),
  });

  test("keeps open statuses whose endTime has passed", () => {
    const got = selectOverdueCandidates(
        [
          rec("pend", -10 * MIN, "pending"),
          rec("prog", -1 * HOUR, "in_progress"),
          rec("legacy", -20 * MIN, "confirmed"),
          rec("edgeNow", 0, "pending"),
          rec("notEnded", 30 * MIN, "pending"),
          rec("done", -10 * MIN, "done"),
          rec("completedLegacy", -10 * MIN, "completed"),
          rec("cxl", -10 * MIN, "cancelled"),
        ],
        NOW,
    );
    expect(got.map((r) => r.id).sort())
        .toEqual(["edgeNow", "legacy", "pend", "prog"]);
  });

  test("drops a record with no endTime", () => {
    expect(selectOverdueCandidates(
        [{id: "noEnd", status: "pending"}], NOW)).toEqual([]);
  });

  test("drops a job that ended before the lookback window", () => {
    // The window was 24 h while this sweep owned an `every 15 minutes` timer.
    // It rides the 5-minute one now, so 24 h meant re-reading a job left open
    // — and re-attempting its ledger create — on 287 further sweeps after the
    // one that actually prompted, every attempt guaranteed to fail
    // ALREADY_EXISTS. 2 h still gives 24 examinations per job.
    expect(selectOverdueCandidates(
        [rec("ancient", -3 * HOUR, "pending")], NOW)).toEqual([]);
    // Just inside it is still a candidate, so the boundary is the window and
    // not an off-by-an-hour.
    expect(selectOverdueCandidates(
        [rec("recent", -110 * MIN, "pending")], NOW)).toHaveLength(1);
  });

  test("drops a personal block — there is no job to finish", () => {
    const personal = {...rec("personal", -10 * MIN, "pending"),
      isPersonal: true};
    expect(selectOverdueCandidates([personal], NOW)).toEqual([]);
    // The same record without the flag is still a candidate.
    expect(selectOverdueCandidates(
        [rec("personal", -10 * MIN, "pending")], NOW)).toHaveLength(1);
  });
});

describe("tomorrowWindowToronto", () => {
  test("bounds tomorrow at Toronto midnight (EDT = 04:00Z)", () => {
    const {start, end} = tomorrowWindowToronto(NOW);
    expect(start.toISOString()).toBe("2026-07-09T04:00:00.000Z");
    expect(end.toISOString()).toBe("2026-07-10T04:00:00.000Z");
  });
});

describe("groupTomorrowsJobsByEmployee", () => {
  test("groups tomorrow's jobs by employee, cancelled excluded, sorted", () => {
    const jobs = [
      {id: "j1", employeeIds: ["e1"], startTime: new Date(
          "2026-07-09T18:00:00Z")},
      {id: "j2", employeeIds: ["e1", "e2"], startTime: new Date(
          "2026-07-09T13:00:00Z")},
      {id: "today", employeeIds: ["e1"], startTime: new Date(
          "2026-07-09T02:00:00Z")}, // 22:00 Toronto today
      {id: "dayAfter", employeeIds: ["e1"], startTime: new Date(
          "2026-07-10T05:00:00Z")},
      {id: "cxl", employeeIds: ["e1"], status: "cancelled", startTime: new Date(
          "2026-07-09T15:00:00Z")},
    ];
    const grouped = groupTomorrowsJobsByEmployee(jobs, NOW);
    expect(grouped.e1.map((j) => j.id)).toEqual(["j2", "j1"]);
    expect(grouped.e2.map((j) => j.id)).toEqual(["j2"]);
  });

  test("a multi-day run started days ago still counts for tomorrow", () => {
    // The crew is on site tomorrow. Bucketing on startTime alone told them
    // "no jobs tomorrow" while they were mid-run.
    const grouped = groupTomorrowsJobsByEmployee(
        [{
          id: "run",
          employeeIds: ["e1"],
          startTime: new Date("2026-07-06T13:00:00Z"),
          endTime: new Date("2026-07-15T21:00:00Z"),
        }],
        NOW,
    );
    expect(grouped.e1.map((j) => j.id)).toEqual(["run"]);
  });

  test("a run that ended before tomorrow is still excluded", () => {
    const grouped = groupTomorrowsJobsByEmployee(
        [{
          id: "over",
          employeeIds: ["e1"],
          startTime: new Date("2026-07-01T13:00:00Z"),
          endTime: new Date("2026-07-04T21:00:00Z"),
        }],
        NOW,
    );
    expect(grouped.e1).toBeUndefined();
  });
});

describe("buildNotificationMessage", () => {
  const ctx = {
    clientName: "Alice",
    startTime: new Date("2026-07-08T18:30:00Z"),
    address: "123 Main St",
  };

  test("assigned EN/FR titles differ and body names the client", () => {
    const en = buildNotificationMessage("assigned", ctx, "en");
    const fr = buildNotificationMessage("assigned", ctx, "fr");
    expect(en.title).toBe("New job assigned");
    expect(fr.title).toBe("Nouvelle visite assignée");
    expect(en.body).toContain("Alice");
    expect(fr.body).toContain("Alice");
  });

  test("reminder appends the address; omits it when blank", () => {
    const withAddr = buildNotificationMessage("reminder", ctx, "en");
    const noAddr = buildNotificationMessage(
        "reminder",
        {...ctx, address: ""},
        "en",
    );
    expect(withAddr.body).toContain("123 Main St");
    expect(noAddr.body).not.toContain("123 Main St");
  });

  test("a personal job is named by its title, not 'Client'", () => {
    const personal = {
      clientName: "",
      title: "Dentist",
      startTime: ctx.startTime,
    };
    expect(buildNotificationMessage("assigned", personal, "en").body)
        .toContain("Dentist");
    expect(buildNotificationMessage("assigned", personal, "fr").body)
        .toContain("Dentist");
    expect(buildDigestMessage([personal], "en").body).toContain("Dentist");
    expect(buildDigestMessage([personal], "en").body)
        .not.toContain("Client");
  });

  test("an all-day block speaks the date, never 12:00 a.m.", () => {
    const allDay = {
      clientName: "",
      title: "Vacation",
      // Midnight Toronto on Wed 2026-07-08.
      startTime: new Date("2026-07-08T04:00:00Z"),
      isAllDay: true,
    };
    const en = buildNotificationMessage("assigned", allDay, "en");
    expect(en.body).toBe("Vacation · Wed, Jul 8");
    expect(en.body).not.toMatch(/12:00/);
    const fr = buildNotificationMessage("cancelled", allDay, "fr");
    expect(fr.body).not.toMatch(/00:00|0 h/);
    // A timed job is unchanged.
    expect(buildNotificationMessage("assigned", ctx, "en").body)
        .toContain("2:30");
  });

  test("a multi-day run reads as a date range, not just day one", () => {
    // Aug 1 09:00 → Aug 5 17:00 Toronto. Naming only the first morning tells a
    // tech nothing about a job they are on for the rest of the week.
    const run = {
      clientName: "Alice",
      startTime: new Date("2026-08-01T13:00:00Z"),
      endTime: new Date("2026-08-05T21:00:00Z"),
    };
    const en = buildNotificationMessage("assigned", run, "en");
    expect(en.body).toContain("Sat, Aug 1");
    expect(en.body).toContain("Wed, Aug 5");
    const fr = buildNotificationMessage("assigned", run, "fr");
    expect(fr.body).toContain("5 août");
  });

  test("a night shift's range ends on the last night, not the morning after",
      () => {
        // Aug 1 22:00 → Aug 4 06:00 = three nights, the last starting Aug 3.
        const nights = {
          clientName: "Alice",
          startTime: new Date("2026-08-02T02:00:00Z"),
          endTime: new Date("2026-08-04T10:00:00Z"),
        };
        const en = buildNotificationMessage("assigned", nights, "en");
        expect(en.body).toContain("Mon, Aug 3");
        expect(en.body).not.toContain("Aug 4");
      });

  test("a single-day job keeps its single date", () => {
    const oneDay = {
      clientName: "Alice",
      startTime: new Date("2026-07-08T18:30:00Z"),
      endTime: new Date("2026-07-08T20:30:00Z"),
    };
    expect(buildNotificationMessage("assigned", oneDay, "en").body)
        .toBe("Alice · Wed, Jul 8, 2:30 p.m.");
  });

  test("a context with no endTime is unchanged", () => {
    expect(buildNotificationMessage("assigned", ctx, "en").body)
        .toBe("Alice · Wed, Jul 8, 2:30 p.m.");
  });

  test("blank client name falls back", () => {
    const en = buildNotificationMessage(
        "assigned",
        {clientName: "", startTime: ctx.startTime},
        "en",
    );
    expect(en.body).toContain("Client");
  });

  test("leaveNow EN/FR carry the drive time and address", () => {
    const travelCtx = {...ctx, travelMinutes: 25};
    const en = buildNotificationMessage("leaveNow", travelCtx, "en");
    const fr = buildNotificationMessage("leaveNow", travelCtx, "fr");
    expect(en.title).toBe("Time to leave — Alice at 2:30 p.m.");
    expect(en.body).toBe("About 25 min drive · 123 Main St");
    expect(fr.title).toBe("C'est l'heure de partir — Alice à 14 h 30");
    expect(fr.body).toBe("Environ 25 min de route · 123 Main St");
  });

  test("leaveNow omits a blank address", () => {
    const en = buildNotificationMessage(
        "leaveNow",
        {...ctx, address: " ", travelMinutes: 25},
        "en",
    );
    expect(en.body).toBe("About 25 min drive");
  });

  test("doneCheck EN/FR nudges to update the status", () => {
    const en = buildNotificationMessage("doneCheck", ctx, "en");
    const fr = buildNotificationMessage("doneCheck", ctx, "fr");
    expect(en.title).toBe("Job finished?");
    expect(en.body).toBe(
        "Is the job for Alice done yet? Open the app to update its status.");
    expect(fr.title).toBe("Travail terminé ?");
    expect(fr.body).toBe(
        "Le travail pour Alice est-il terminé ? " +
        "Ouvrez l'application pour mettre à jour son statut.");
  });

  test("repeating assigned announces the recurrence EN/FR", () => {
    const en = buildNotificationMessage(
        "assigned", {...ctx, repeat: "six_months"}, "en");
    const fr = buildNotificationMessage(
        "assigned", {...ctx, repeat: "one_year"}, "fr");
    expect(en.title).toBe("New repeating job assigned");
    expect(en.body).toContain("repeats every 6 months");
    expect(fr.title).toBe("Nouvelle visite récurrente");
    expect(fr.body).toContain("chaque année");
  });

  test("repeat none/absent falls back to the plain assigned message", () => {
    const withNone = buildNotificationMessage(
        "assigned", {...ctx, repeat: "none"}, "en");
    const absent = buildNotificationMessage("assigned", ctx, "en");
    expect(withNone.title).toBe("New job assigned");
    expect(absent.title).toBe("New job assigned");
  });

  test("every repeat interval the app can store has a phrase", () => {
    // Mirrors RepeatInterval (repeat_interval.dart). A missing case here ships
    // a job announced as one-off when it repeats.
    for (const raw of ["four_months", "six_months", "one_year"]) {
      for (const locale of ["en", "fr"]) {
        const msg = buildNotificationMessage(
            "assigned", {...ctx, repeat: raw}, locale);
        expect(msg.title).toBe(locale === "fr" ?
          "Nouvelle visite récurrente" : "New repeating job assigned");
      }
    }
    expect(buildNotificationMessage(
        "assigned", {...ctx, repeat: "four_months"}, "en").body,
    ).toContain("repeats every 4 months");
  });

  test("an unknown kind yields empty strings rather than a blank push", () => {
    // The fan-out treats an empty title/body as nothing to send; a partial
    // message would reach a Lock Screen looking broken.
    expect(buildNotificationMessage("nope", ctx, "en"))
        .toEqual({title: "", body: ""});
  });

  test("a null context does not throw", () => {
    expect(buildNotificationMessage("assigned", null, "en").body)
        .toContain("Client");
  });

  test("an unknown locale falls back to EN, never to nothing", () => {
    expect(buildNotificationMessage("assigned", ctx, "es").title)
        .toBe("New job assigned");
  });
});

describe("buildDigestMessage", () => {
  const jobs = [
    {clientName: "Bob", startTime: new Date("2026-07-09T20:00:00Z")},
    {clientName: "Al", startTime: new Date("2026-07-09T13:00:00Z")},
  ];

  test("EN counts jobs and names the earliest first", () => {
    const en = buildDigestMessage(jobs, "en");
    expect(en.body).toContain("2 jobs tomorrow");
    expect(en.body).toContain("Al");
  });

  test("FR variant", () => {
    const fr = buildDigestMessage(jobs, "fr");
    expect(fr.body).toContain("2 visites demain");
  });

  test("singular noun for one job", () => {
    const en = buildDigestMessage([jobs[0]], "en");
    expect(en.body).toContain("1 job tomorrow");
  });

  test("an all-day first job reads 'all day', not a clock time", () => {
    const allDay = {
      clientName: "",
      title: "Vacation",
      startTime: new Date("2026-07-09T04:00:00Z"),
      isAllDay: true,
    };
    expect(buildDigestMessage([allDay], "en").body)
        .toContain("First: Vacation · all day.");
    expect(buildDigestMessage([allDay], "fr").body)
        .toContain("Première : Vacation · toute la journée.");
  });
});

describe("overduePromptLedgerId / isStaleTokenError", () => {
  test("overdue ledger id joins appointment, endTime and recipient", () => {
    expect(overduePromptLedgerId("a", 456, "e1")).toBe("a_456_e1");
  });

  test("stale-token error codes", () => {
    expect(isStaleTokenError(
        "messaging/registration-token-not-registered")).toBe(true);
    expect(isStaleTokenError(
        "messaging/invalid-registration-token")).toBe(true);
    expect(isStaleTokenError("messaging/internal-error")).toBe(false);
    // This code is generic — it could be a payload problem rather than a
    // dead token, so we don't treat it as stale.
    expect(isStaleTokenError("messaging/invalid-argument")).toBe(false);
  });
});

// ----- orchestration with mocks --------------------------------------------

/**
 * Builds a minimal Firestore mock for the orchestration tests, with
 * collection-scoped ledger ids and every appointment `where()` recorded.
 * @param {!Object} config users/tokens/appointments/ledgerExisting fixtures.
 * @return {!Object} `{db, deletedTokens, ledgerCreates, ledgerDeletes,
 *   appointmentQueries}`.
 */
function makeDb(config) {
  const deletedTokens = [];
  const ledgerCreates = [];
  const ledgerDeletes = [];
  const appointmentQueries = [];
  const appointmentOrders = [];
  // Every users/{id} and users/{id}/fcmTokens read, so a test can assert both
  // that a recipient is read at most once per pass and that an unreachable
  // one costs nothing beyond that read.
  const userReads = [];
  const tokenReads = [];
  const seriesClaims = new Map(config.seriesClaims || []);
  const existing = new Set(config.ledgerExisting || []);
  const db = {
    collection(name) {
      if (name === "users") {
        return {
          doc(id) {
            return {
              get: async () => {
                userReads.push(id);
                return {
                  exists: !!config.users[id],
                  data: () => config.users[id],
                };
              },
              collection() {
                return {
                  get: async () => {
                    tokenReads.push(id);
                    return {
                      docs: (config.tokens[id] || []).map((t) => ({
                        id: t.id,
                        data: () => ({locale: t.locale}),
                        ref: {
                          delete: async () => {
                            deletedTokens.push(t.id);
                          },
                        },
                      })),
                    };
                  },
                };
              },
            };
          },
        };
      }
      if (name === "appointments") {
        const q = {
          where(field, op, value) {
            appointmentQueries.push({field, op, value});
            return q;
          },
          orderBy(field, direction) {
            appointmentOrders.push({field, direction});
            return q;
          },
          limit() {
            return q;
          },
          get: async () => ({
            docs: (config.appointments || []).map((r) => ({
              id: r.id,
              data: () => r,
            })),
          }),
        };
        return q;
      }
      if (name === "appointmentReminders" ||
          name === "appointmentOverduePrompts") {
        return {
          doc(id) {
            const key = `${name}/${id}`;
            return {
              create: async (data) => {
                if (existing.has(key)) {
                  const e = new Error("exists");
                  e.code = 6;
                  throw e;
                }
                ledgerCreates.push({key, data});
              },
              delete: async () => {
                ledgerDeletes.push(key);
              },
            };
          },
        };
      }
      if (name === "appointmentSeriesNotices") {
        return {
          doc(id) {
            return {
              create: async (data) => {
                if (seriesClaims.has(id)) {
                  const e = new Error("exists");
                  e.code = 6;
                  throw e;
                }
                seriesClaims.set(id, data);
              },
              get: async () => ({
                get: (field) => (seriesClaims.get(id) || {})[field],
              }),
              set: async (data) => {
                seriesClaims.set(id, data);
              },
            };
          },
        };
      }
      return {doc: () => ({})};
    },
  };
  return {
    db, deletedTokens, ledgerCreates, ledgerDeletes, appointmentQueries,
    appointmentOrders,
    seriesClaims, userReads, tokenReads,
  };
}

/**
 * Builds a Messaging mock whose sendEach records the messages it receives.
 * @param {function(string): !Object=} resultFor Optional per-token response.
 * @return {!Object} `{sent, sendEach}`.
 */
function makeMessaging(resultFor) {
  const sent = [];
  return {
    sent,
    sendEach: async (messages) => {
      sent.push(...messages);
      return {
        responses: messages.map((m) =>
          resultFor ? resultFor(m.token) : {success: true}),
      };
    },
  };
}

const silentLogger = {warn: () => {}, info: () => {}, error: () => {}};

describe("handleAppointmentWrite repeat-series claim", () => {
  // A "this and all future" edit writes every sibling in one client batch, so
  // without a claim the tech would get one push per sibling instead of one.
  const sibling = (id) => ({
    id,
    seriesId: "series-1",
    employeeIds: ["e1"],
    startTime: future(3 * HOUR),
    status: "pending",
  });

  const runDelete = (db, messaging, id) => handleAppointmentWrite(
      id,
      sibling(id),
      null,
      {db, messaging, now: NOW, logger: silentLogger},
  );

  test("series cancel/delete notifies the employee only once", async () => {
    const {db} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t-en", locale: "en"}]},
    });
    const messaging = makeMessaging();
    const first = await runDelete(db, messaging, "occ-1");
    const second = await runDelete(db, messaging, "occ-2");
    const third = await runDelete(db, messaging, "occ-3");

    expect(first.sent).toBe(1);
    expect(second.sent).toBe(0);
    expect(third.sent).toBe(0);
    expect(messaging.sent).toHaveLength(1);
  });

  test("a non-series appointment is never suppressed", async () => {
    const {db} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t-en", locale: "en"}]},
    });
    const messaging = makeMessaging();
    const one = {
      employeeIds: ["e1"], startTime: future(3 * HOUR), status: "pending",
    };
    const a = await handleAppointmentWrite(
        "solo-1", one, null, {db, messaging, now: NOW, logger: silentLogger});
    const b = await handleAppointmentWrite(
        "solo-2", one, null, {db, messaging, now: NOW, logger: silentLogger});
    expect(a.sent).toBe(1);
    expect(b.sent).toBe(1);
  });

  test("a later separate operation on the same series notifies again",
      async () => {
        const stale = new Date(
            NOW.getTime() - SERIES_CLAIM_WINDOW_MS - 1000);
        const {db} = makeDb({
          users: {e1: {role: "employee", status: "active"}},
          tokens: {e1: [{id: "t-en", locale: "en"}]},
          seriesClaims: [["series-1_cancelled_e1", {createdAt: stale}]],
        });
        const messaging = makeMessaging();
        const res = await runDelete(db, messaging, "occ-9");
        // The existing claim predates the batch window, so it is taken over
        // rather than suppressing a genuinely new operation.
        expect(res.sent).toBe(1);
      });

  test("fails OPEN: a claim-store error still delivers the push", async () => {
    const {db} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t-en", locale: "en"}]},
    });
    const broken = {
      ...db,
      collection: (name) => name === "appointmentSeriesNotices" ?
        {doc: () => ({create: async () => {
          throw new Error("firestore down");
        }})} :
        db.collection(name),
    };
    const messaging = makeMessaging();
    const res = await runDelete(broken, messaging, "occ-1");
    // Degrading to today's behavior (one push per sibling) beats silently
    // dropping a cancellation for a tech already driving to the job.
    expect(res.sent).toBe(1);
  });

  // On the op-id path, a WRITE (where `after` is present) carries a fresh
  // seriesOpId that every sibling in the same batch shares and no other
  // operation reuses. So the claim is keyed on that op-id, with no time
  // window needed.
  const cancelUpdate = (db, messaging, id, opId) => {
    const before = {
      seriesId: "series-1", employeeIds: ["e1"],
      startTime: future(3 * HOUR), status: "pending",
    };
    const after = {...before, status: "cancelled", seriesOpId: opId};
    return handleAppointmentWrite(
        id, before, after, {db, messaging, now: NOW, logger: silentLogger});
  };

  test("one op-id collapses its whole batch to a single push", async () => {
    const {db} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t-en", locale: "en"}]},
    });
    const messaging = makeMessaging();
    const first = await cancelUpdate(db, messaging, "occ-1", "op-A");
    const second = await cancelUpdate(db, messaging, "occ-2", "op-A");
    const third = await cancelUpdate(db, messaging, "occ-3", "op-A");
    expect(first.sent).toBe(1);
    expect(second.sent).toBe(0);
    expect(third.sent).toBe(0);
    expect(messaging.sent).toHaveLength(1);
  });

  test("two separate operations each notify, even back-to-back", async () => {
    // Distinct op-ids keep separate cancellations (e.g. Tuesday's then
    // Thursday's) from suppressing each other regardless of timing.
    const {db} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t-en", locale: "en"}]},
    });
    const messaging = makeMessaging();
    const tuesday = await cancelUpdate(db, messaging, "tue", "op-A");
    const thursday = await cancelUpdate(db, messaging, "thu", "op-B");
    expect(tuesday.sent).toBe(1);
    expect(thursday.sent).toBe(1);
    expect(messaging.sent).toHaveLength(2);
  });

  test("op-id path suppresses without a stale-takeover read", async () => {
    // A duplicate op-id claim is definitive since it's the same batch, so
    // create() alone can resolve the collision — no need for a get()/set()
    // round-trip.
    const {db, seriesClaims} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t-en", locale: "en"}]},
      seriesClaims: [["op_op-A_cancelled_e1", {createdAt: NOW}]],
    });
    const messaging = makeMessaging();
    const res = await cancelUpdate(db, messaging, "occ-1", "op-A");
    expect(res.sent).toBe(0);
    // The claim doc is untouched (not overwritten by a takeover set()).
    expect(seriesClaims.get("op_op-A_cancelled_e1").createdAt).toBe(NOW);
  });
});

describe("handleAppointmentWrite", () => {
  test("sends one message per live token of an active employee", async () => {
    const {db} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t-en", locale: "en"}, {id: "t-fr", locale: "fr"}]},
    });
    const messaging = makeMessaging();
    const res = await handleAppointmentWrite(
        "appt1",
        null,
        {employeeIds: ["e1"], startTime: future(3 * HOUR)},
        {db, messaging, now: NOW, logger: silentLogger},
    );
    expect(res).toEqual({events: 1, sent: 2});
    expect(messaging.sent).toHaveLength(2);
    // Delivery hints are always set.
    expect(messaging.sent[0].android.priority).toBe("high");
    expect(messaging.sent[0].apns.payload.aps.sound).toBe("default");
    expect(messaging.sent[0].data.appointmentId).toBe("appt1");
    expect(messaging.sent[0].data.kind).toBe("assigned");
    // A change push carries a fresh widget payload and wakes iOS in the
    // background (content-available) to rewrite the home-screen widget.
    expect(typeof messaging.sent[0].data.widgetPayload).toBe("string");
    expect(messaging.sent[0].apns.payload.aps["content-available"]).toBe(1);
  });

  test("attaches a locale-correct widget payload with the assigned job",
      async () => {
        const {db} = makeDb({
          users: {e1: {role: "employee", status: "active"}},
          tokens: {e1: [
            {id: "t-en", locale: "en"},
            {id: "t-fr", locale: "fr"},
          ]},
          // This is the post-write state that the widget window read sees.
          appointments: [{
            id: "appt1",
            employeeIds: ["e1"],
            startTime: future(3 * HOUR),
            status: "pending",
            clientName: "Acme",
          }],
        });
        const messaging = makeMessaging();
        await handleAppointmentWrite(
            "appt1",
            null,
            {employeeIds: ["e1"], startTime: future(3 * HOUR)},
            {db, messaging, now: NOW, logger: silentLogger},
        );
        const byToken = Object.fromEntries(
            messaging.sent.map((m) => [m.token, m]));
        const en = JSON.parse(byToken["t-en"].data.widgetPayload);
        const fr = JSON.parse(byToken["t-fr"].data.widgetPayload);
        expect(en.locale).toBe("en");
        expect(fr.locale).toBe("fr");
        expect(en.todayJobs).toHaveLength(1);
        expect(en.todayJobs[0].id).toBe("appt1");
        expect(en.todayJobs[0].clientName).toBe("Acme");
        // startTime is an absolute UTC instant (…Z) for the Swift decoder.
        expect(en.todayJobs[0].startTime).toBe(future(3 * HOUR).toISOString());
      });

  test("the widget window asks for an OVERLAP, not a back-scan", async () => {
    // This read runs once per notified assignee on every appointment write,
    // so its width is paid on every save. It used to floor `startTime` at
    // `todayStart - MAX_APPOINTMENT_SPAN_MS` — a fortnight of this employee's
    // history — purely so a multi-day run that began earlier but still WORKS
    // today would be visible, then let buildWidgetPayload drop the rest.
    // Asking `endTime >= todayStart` says exactly that instead, and returns
    // only the jobs the payload can actually use.
    const {db, appointmentQueries} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t-en", locale: "en"}]},
      appointments: [],
    });
    await handleAppointmentWrite(
        "appt1",
        null,
        {employeeIds: ["e1"], startTime: future(3 * HOUR)},
        {db, messaging: makeMessaging(), now: NOW, logger: silentLogger},
    );

    const fields = appointmentQueries.map((q) => `${q.field} ${q.op}`);
    expect(fields).toEqual([
      "employeeIds array-contains",
      "endTime >=",
      "startTime <",
    ]);
    // The floor is today's midnight itself, with nothing subtracted — the
    // regression to guard against is someone re-widening it.
    const floor = appointmentQueries.find((q) => q.field === "endTime").value;
    const ceiling =
      appointmentQueries.find((q) => q.field === "startTime").value;
    expect(ceiling.getTime() - floor.getTime()).toBe(3 * 24 * HOUR);
  });

  test("cancelling a job yields a widget payload without it", async () => {
    const {db} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t-en", locale: "en"}]},
      // The cancelled doc still exists but is terminal -> filtered out.
      appointments: [{
        id: "appt1",
        employeeIds: ["e1"],
        startTime: future(3 * HOUR),
        status: "cancelled",
        clientName: "Acme",
      }],
    });
    const messaging = makeMessaging();
    await handleAppointmentWrite(
        "appt1",
        {employeeIds: ["e1"], startTime: future(3 * HOUR), status: "pending"},
        {employeeIds: ["e1"], startTime: future(3 * HOUR), status: "cancelled"},
        {db, messaging, now: NOW, logger: silentLogger},
    );
    expect(messaging.sent[0].data.kind).toBe("cancelled");
    const payload = JSON.parse(messaging.sent[0].data.widgetPayload);
    expect(payload.todayJobs).toHaveLength(0);
    expect(payload.tomorrowJobs).toHaveLength(0);
  });

  test("skips a non-active or non-employee user", async () => {
    const {db} = makeDb({
      users: {e1: {role: "employee", status: "invited"}},
      tokens: {e1: [{id: "t", locale: "en"}]},
    });
    const messaging = makeMessaging();
    const res = await handleAppointmentWrite(
        "appt1",
        null,
        {employeeIds: ["e1"], startTime: future(3 * HOUR)},
        {db, messaging, now: NOW, logger: silentLogger},
    );
    expect(res.sent).toBe(0);
    expect(messaging.sent).toHaveLength(0);
  });

  test("deletes a token doc FCM reports as stale", async () => {
    const {db, deletedTokens} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "good", locale: "en"}, {id: "dead", locale: "en"}]},
    });
    const messaging = makeMessaging((token) =>
      token === "dead" ?
        {success: false, error: {
          code: "messaging/registration-token-not-registered",
        }} :
        {success: true});
    const res = await handleAppointmentWrite(
        "appt1",
        null,
        {employeeIds: ["e1"], startTime: future(3 * HOUR)},
        {db, messaging, now: NOW, logger: silentLogger},
    );
    expect(res.sent).toBe(1);
    expect(deletedTokens).toEqual(["dead"]);
  });

  test("no events -> no sends", async () => {
    const {db} = makeDb({users: {}, tokens: {}});
    const messaging = makeMessaging();
    const res = await handleAppointmentWrite(
        "appt1",
        null,
        {employeeIds: ["e1"], startTime: future(-1 * HOUR)},
        {db, messaging, now: NOW, logger: silentLogger},
    );
    expect(res).toEqual({events: 0, sent: 0});
  });

  test("an active admin assignee gets NO change-driven push", async () => {
    const {db} = makeDb({
      users: {a1: {role: "admin", status: "active"}},
      tokens: {a1: [{id: "t", locale: "en"}]},
    });
    const messaging = makeMessaging();
    const res = await handleAppointmentWrite(
        "appt1",
        null,
        {employeeIds: ["a1"], startTime: future(3 * HOUR)},
        {db, messaging, now: NOW, logger: silentLogger},
    );
    // Assignment/reschedule/cancel pushes are employee-only. An admin
    // usually makes those edits themselves, so we don't push back their
    // own change.
    expect(res.sent).toBe(0);
    expect(messaging.sent).toHaveLength(0);
  });

  test("an unreachable recipient costs no widget-window query", async () => {
    // The eligibility gate runs BEFORE the work that composes a push. An
    // admin assignee is refused by CHANGE_RECIPIENT_ROLES no matter what, so
    // the widget window read that feeds the payload can never be used — and it
    // is a real Firestore query, run once per assignee on every appointment
    // write.
    const {db, appointmentQueries} = makeDb({
      users: {a1: {role: "admin", status: "active"}},
      tokens: {a1: [{id: "t", locale: "en"}]},
    });
    await handleAppointmentWrite(
        "appt1",
        null,
        {employeeIds: ["a1"], startTime: future(3 * HOUR)},
        {db, messaging: makeMessaging(), now: NOW, logger: silentLogger},
    );
    expect(appointmentQueries).toEqual([]);
  });

  test("an assignee with no live token composes nothing", async () => {
    const {db, appointmentQueries} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: []},
    });
    const messaging = makeMessaging();
    const res = await handleAppointmentWrite(
        "appt1",
        null,
        {employeeIds: ["e1"], startTime: future(3 * HOUR)},
        {db, messaging, now: NOW, logger: silentLogger},
    );
    expect(res.sent).toBe(0);
    expect(appointmentQueries).toEqual([]);
    expect(messaging.sent).toHaveLength(0);
  });

  test("an unreachable series assignee burns no claim-ledger write",
      async () => {
        // The claim is keyed per (operation, kind, EMPLOYEE), so skipping it
        // for someone the push can never reach only ever suppresses that same
        // person's sends — which were already zero.
        const {db, seriesClaims} = makeDb({
          users: {a1: {role: "admin", status: "active"}},
          tokens: {a1: [{id: "t", locale: "en"}]},
        });
        await handleAppointmentWrite(
            "occ-1",
            {
              id: "occ-1", seriesId: "series-1", employeeIds: ["a1"],
              startTime: future(3 * HOUR), status: "pending",
            },
            null,
            {db, messaging: makeMessaging(), now: NOW, logger: silentLogger},
        );
        expect(seriesClaims.size).toBe(0);
      });

  test("two events for one employee read that user once", async () => {
    // One write can accrue events for the same person more than once across a
    // batch of ids; the per-write cache is what stops each one paying for the
    // same user + tokens reads.
    const {db, userReads, tokenReads} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t", locale: "en"}]},
    });
    await handleAppointmentWrite(
        "appt1",
        null,
        {employeeIds: ["e1"], startTime: future(3 * HOUR)},
        {db, messaging: makeMessaging(), now: NOW, logger: silentLogger},
    );
    // The gate reads it; the send that follows reuses that read rather than
    // repeating it.
    expect(userReads).toEqual(["e1"]);
    expect(tokenReads).toEqual(["e1"]);
  });
});

describe("notification_policy re-exports", () => {
  test("notification_utils re-exports every policy symbol by its own name",
      () => {
        // functions/CLAUDE.md states this as an invariant ("re-exports every
        // one of them under its original name") and nothing enforced it — ten
        // of the twenty-one were missing, which is why one jest suite already
        // requires notification_policy directly. A new pure rule must be added
        // to the policy module AND re-exported here.
        const policy = require("../notification_policy");
        const utils = require("../notification_utils");
        const missing = Object.keys(policy)
            .filter((key) => utils[key] !== policy[key]);
        expect(missing).toEqual([]);
      });
});

describe("runOverduePromptSweep", () => {
  const overdueJob = {
    id: "over",
    status: "in_progress",
    clientName: "Alice",
    employeeIds: ["e1"],
    startTime: future(-2 * HOUR),
    endTime: future(-30 * MIN),
  };
  const overdueKey = `appointmentOverduePrompts/${
    overduePromptLedgerId("over", future(-30 * MIN).getTime(), "e1")}`;

  test("writes the endTime-keyed ledger and prompts assignees", async () => {
    const {db, ledgerCreates, ledgerDeletes, appointmentQueries} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t", locale: "en"}]},
      appointments: [
        overdueJob,
        // Still running -> filtered out in code.
        {id: "running", status: "in_progress", employeeIds: ["e1"],
          startTime: future(-1 * HOUR), endTime: future(30 * MIN)},
        // Closed -> filtered out in code.
        {id: "closed", status: "done", employeeIds: ["e1"],
          startTime: future(-2 * HOUR), endTime: future(-30 * MIN)},
      ],
    });
    const messaging = makeMessaging();
    const res = await runOverduePromptSweep(
        {db, messaging, now: NOW, logger: silentLogger},
    );
    expect(res.prompted).toBe(1);
    expect(ledgerCreates.map((c) => c.key)).toEqual([overdueKey]);
    expect(ledgerCreates[0].data.expiresAt).toBeInstanceOf(Date);
    expect(ledgerDeletes).toEqual([]);
    // The query IS the eligibility rule: open statuses, endTime inside
    // OVERDUE_LOOKBACK_MS. Bounding `endTime` rather than `startTime` is what
    // keeps the scan the width of the rule — the old startTime form had to
    // reach back the lookback PLUS the longest bookable span (14 days) to see
    // a multi-day run that had just ended, and re-read that whole fortnight
    // every 15 minutes.
    expect(appointmentQueries).toEqual([
      {field: "status", op: "in",
        value: ["pending", "in_progress", "confirmed"]},
      {field: "endTime", op: ">", value: future(-OVERDUE_LOOKBACK_MS)},
      {field: "endTime", op: "<=", value: NOW},
    ]);
    // Sized against the CADENCE, not a day: this rides the 5-minute reminder
    // timer, so 2 h is 24 examinations of a job left open, where the 24 h it
    // carried over from the deleted 15-minute scheduler was 288.
    expect(OVERDUE_LOOKBACK_MS).toBe(2 * HOUR);
    expect(messaging.sent).toHaveLength(1);
    expect(messaging.sent[0].data).toEqual({
      appointmentId: "over",
      kind: "doneCheck",
    });
    expect(messaging.sent[0].notification.body).toContain("Alice");
  });

  test("an existing ledger doc suppresses a re-prompt", async () => {
    const {db} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t", locale: "en"}]},
      appointments: [overdueJob],
      ledgerExisting: [overdueKey],
    });
    const messaging = makeMessaging();
    const res = await runOverduePromptSweep(
        {db, messaging, now: NOW, logger: silentLogger},
    );
    expect(res.prompted).toBe(0);
    expect(messaging.sent).toHaveLength(0);
  });

  test("a zero-delivery assignee burns no claim", async () => {
    // The assignee is active but has no fcmTokens yet, as if on a fresh
    // install. Reachability is now checked BEFORE the claim, so nothing is
    // written at all — "no ledger" and "written then released" are
    // indistinguishable to the next sweep, which is what keeps the late-token
    // retry below working.
    const {db, ledgerCreates, ledgerDeletes} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {},
      appointments: [overdueJob],
    });
    const messaging = makeMessaging();
    const res = await runOverduePromptSweep(
        {db, messaging, now: NOW, logger: silentLogger},
    );
    expect(res.prompted).toBe(0);
    expect(ledgerCreates).toEqual([]);
    expect(ledgerDeletes).toEqual([]);
  });

  test("a thrown send releases the claim and continues", async () => {
    const other = {...overdueJob, id: "other", endTime: future(-40 * MIN)};
    const {db, ledgerCreates, ledgerDeletes} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t", locale: "en"}]},
      appointments: [overdueJob, other],
    });
    const messaging = {
      sendEach: async () => {
        throw new Error("transient FCM outage");
      },
    };
    const res = await runOverduePromptSweep(
        {db, messaging, now: NOW, logger: silentLogger},
    );
    // Both candidates were attempted (no sweep abort) and both claims were
    // released.
    expect(res.prompted).toBe(0);
    expect(ledgerCreates).toHaveLength(2);
    expect(ledgerDeletes).toHaveLength(2);
  });
});

describe("runDailyDigest", () => {
  test("sends one digest per employee with a job tomorrow", async () => {
    const {db} = makeDb({
      users: {
        e1: {role: "employee", status: "active"},
        e2: {role: "employee", status: "active"},
      },
      tokens: {
        e1: [{id: "t1", locale: "en"}],
        e2: [{id: "t2", locale: "fr"}],
      },
      appointments: [
        {id: "j1", status: "pending", employeeIds: ["e1"],
          startTime: new Date("2026-07-09T13:00:00Z")},
        {id: "j2", status: "pending", employeeIds: ["e2"],
          startTime: new Date("2026-07-09T18:00:00Z")},
        {id: "today", status: "pending", employeeIds: ["e1"],
          startTime: new Date("2026-07-08T18:00:00Z")},
      ],
    });
    const messaging = makeMessaging();
    const res = await runDailyDigest(
        {db, messaging, now: NOW, logger: silentLogger},
    );
    expect(res.digests).toBe(2);
    expect(messaging.sent).toHaveLength(2);
  });

  test("queries every open status, including in_progress", async () => {
    // This is a regression test: the digest's hardcoded status list used to
    // disagree with its own filter, silently dropping in_progress jobs from
    // the 18:00 digest.
    const {db, appointmentQueries} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: [{id: "t1", locale: "en"}]},
      appointments: [
        {id: "j1", status: "in_progress", employeeIds: ["e1"],
          startTime: new Date("2026-07-09T13:00:00Z")},
      ],
    });
    const messaging = makeMessaging();
    const res = await runDailyDigest(
        {db, messaging, now: NOW, logger: silentLogger},
    );

    const statusQuery = appointmentQueries.find((q) => q.field === "status");
    expect(statusQuery.value).toEqual(expect.arrayContaining(["in_progress"]));
    expect(statusQuery.value).toEqual(OPEN_STATUSES);
    expect(res.digests).toBe(1);
  });

  test("orders startTime DESC so the cap keeps tomorrow, not a stale tail",
      async () => {
        // The query floor is 15 days in the PAST (a run that began earlier can
        // still be on site tomorrow), so ASCENDING made DIGEST_SWEEP_MAX keep
        // the OLDEST open jobs and discard tomorrow's — every crew would get
        // no digest at all once the stale tail exceeded the cap.
        const {db, appointmentOrders} = makeDb({
          users: {e1: {role: "employee", status: "active"}},
          tokens: {e1: [{id: "t1", locale: "en"}]},
          appointments: [
            {id: "j1", status: "pending", employeeIds: ["e1"],
              startTime: new Date("2026-07-09T13:00:00Z")},
          ],
        });

        await runDailyDigest({db, messaging: makeMessaging(), now: NOW,
          logger: silentLogger});

        expect(appointmentOrders).toContainEqual(
            {field: "startTime", direction: "desc"});
      });

  test("an unreachable employee costs no widget-window read", async () => {
    // Reachability is asked before `fetchEmployeeWidgetWindow`, the order
    // handleAppointmentWrite already establishes: otherwise a tokenless
    // active employee costs a 200-doc read and a payload build every day for
    // a send that returns 0.
    const {db, tokenReads, appointmentQueries} = makeDb({
      users: {e1: {role: "employee", status: "active"}},
      tokens: {e1: []},
      appointments: [
        {id: "j1", status: "pending", employeeIds: ["e1"],
          startTime: new Date("2026-07-09T13:00:00Z")},
      ],
    });

    const res = await runDailyDigest({db, messaging: makeMessaging(), now: NOW,
      logger: silentLogger});

    expect(res.digests).toBe(0);
    expect(tokenReads).toEqual(["e1"]);
    // The candidate sweep's own query only — no per-employee widget window.
    expect(appointmentQueries.filter(
        (q) => q.field === "employeeIds")).toEqual([]);
  });
});

// ----- deliverRecipientOnce -------------------------------------------------

/**
 * Wraps `makeDb`'s users/tokens machinery with a ledger collection whose
 * `.doc()` rejects a slash SYNCHRONOUSLY, the way real Firestore does, and
 * whose create/delete can be made to fail.
 * @param {!Object} config `{users, tokens, existing, createThrows,
 *   deleteThrows}`.
 * @return {!Object} `{db, created, deleted}`.
 */
function makeLedgerDb(config) {
  const base = makeDb({users: config.users || {}, tokens: config.tokens || {}});
  const created = [];
  const deleted = [];
  const existing = new Set(config.existing || []);
  const db = {
    collection(name) {
      if (name === "users") return base.db.collection(name);
      return {
        doc(id) {
          if (String(id).includes("/")) {
            throw new Error(`Invalid document reference: ${id}`);
          }
          return {
            create: async (body) => {
              if (config.createThrows) throw config.createThrows;
              if (existing.has(id)) {
                const err = new Error("already exists");
                err.code = 6;
                throw err;
              }
              existing.add(id);
              created.push({id, body});
            },
            delete: async () => {
              if (config.deleteThrows) throw config.deleteThrows;
              deleted.push(id);
            },
          };
        },
      };
    },
  };
  return {db, created, deleted};
}

describe("deliverRecipientOnce", () => {
  // The at-most-once primitive the WHOLE reminder system sits on: the travel
  // sweep, the overdue "job finished?" nudge, and (via its return value) the
  // Live Activity card start all hang off this one claim.
  const ACTIVE = {e1: {role: "employee", status: "active"}};
  const LEDGER_ID = "appt1_1700000000000_e1";

  const opts = (over) => ({
    collection: "appointmentReminders",
    ledgerId: LEDGER_ID,
    appointmentId: "appt1",
    employeeDocId: "e1",
    kind: "leaveNow",
    buildMsg: () => ({title: "Time to leave", body: "Head to the job"}),
    nowDate: NOW,
    label: "reminder",
    roles: TIMED_RECIPIENT_ROLES,
    ...over,
  });

  const run = (db, messaging, over) => deliverRecipientOnce(
      {db, messaging, now: NOW, logger: silentLogger}, opts(over));

  test("claims, sends, and returns the delivered count", async () => {
    const {db, created, deleted} = makeLedgerDb({
      users: ACTIVE,
      tokens: {e1: [{id: "t1", locale: "en"}, {id: "t2", locale: "fr"}]},
    });
    const messaging = makeMessaging();

    expect(await run(db, messaging)).toBe(2);
    expect(created).toHaveLength(1);
    // A delivered claim is KEPT — releasing it here would re-notify on the
    // next 5-minute sweep.
    expect(deleted).toEqual([]);
    expect(messaging.sent).toHaveLength(2);
  });

  test("a second pass for the same recipient sends nothing", async () => {
    // THE dedupe contract: `create()` fails-if-exists, and an already-exists
    // error means "someone already delivered this" -> 0, before any send.
    // The travel sweep runs every 5 minutes over a 90-minute window, so a
    // reminder would otherwise fire ~18 times.
    const {db, created, deleted} = makeLedgerDb({
      users: ACTIVE,
      tokens: {e1: [{id: "t1", locale: "en"}]},
    });
    const messaging = makeMessaging();

    expect(await run(db, messaging)).toBe(1);
    expect(await run(db, messaging)).toBe(0);
    expect(created).toHaveLength(1);
    expect(messaging.sent).toHaveLength(1);
    // And the replay must NOT release the claim the first pass earned, or
    // every other sweep would re-deliver.
    expect(deleted).toEqual([]);
  });

  test("the string form of already-exists dedupes too", async () => {
    // The Admin SDK surfaces this as numeric 6 or as "already-exists"
    // depending on the path; treating only one as a dedupe re-pushes.
    const err = new Error("already exists");
    err.code = "already-exists";
    const {db, deleted} = makeLedgerDb({
      users: ACTIVE,
      tokens: {e1: [{id: "t1", locale: "en"}]},
      createThrows: err,
    });
    const messaging = makeMessaging();

    expect(await run(db, messaging)).toBe(0);
    expect(messaging.sent).toEqual([]);
    expect(deleted).toEqual([]);
  });

  test("a ledger id containing a slash returns 0, not a thrown sweep",
      async () => {
        // `.doc()` throws SYNCHRONOUSLY on such an id, which is why it is
        // built INSIDE the try. The rules only length-check `employeeIds`
        // (CEL cannot iterate a list), so one poisoned element is reachable —
        // and an escape here would kill every push for the whole sweep.
        const {db, created} = makeLedgerDb({
          users: ACTIVE,
          tokens: {e1: [{id: "t1", locale: "en"}]},
        });
        const messaging = makeMessaging();

        expect(await run(db, messaging, {ledgerId: "appt1_1_bad/id"})).toBe(0);
        expect(created).toEqual([]);
        expect(messaging.sent).toEqual([]);
      });

  test("a poisoned recipient does not stop the next one delivering",
      async () => {
        // The sweep shape: `Promise.all` over every (job, assignee) pair. One
        // bad id must cost exactly one push, not all of them.
        const {db} = makeLedgerDb({
          users: {...ACTIVE, e2: {role: "employee", status: "active"}},
          tokens: {
            e1: [{id: "t1", locale: "en"}],
            e2: [{id: "t2", locale: "en"}],
          },
        });
        const messaging = makeMessaging();
        const results = await Promise.all([
          run(db, messaging, {ledgerId: "a/b", employeeDocId: "e1"}),
          run(db, messaging, {ledgerId: "ok-e2", employeeDocId: "e2"}),
        ]);

        expect(results).toEqual([0, 1]);
        expect(messaging.sent).toHaveLength(1);
      });

  test("a recipient with no live token burns no claim", async () => {
    // A recipient whose device has not registered a token yet: holding the
    // claim would suppress that reminder forever once the token arrives.
    // Checked before the claim, so it costs no ledger write either — the
    // retry below is what actually matters and is unchanged.
    const {db, created, deleted} = makeLedgerDb({
      users: ACTIVE,
      tokens: {e1: []},
    });
    const messaging = makeMessaging();

    expect(await run(db, messaging)).toBe(0);
    expect(created).toEqual([]);
    expect(deleted).toEqual([]);
    expect(messaging.sent).toEqual([]);
  });

  test("a released claim really is retried on the next sweep", async () => {
    // The point of the release, end to end: the same call after the token
    // registers must deliver.
    const {db} = makeLedgerDb({users: ACTIVE, tokens: {e1: []}});
    expect(await run(db, makeMessaging())).toBe(0);

    const withToken = makeLedgerDb({
      users: ACTIVE,
      tokens: {e1: [{id: "t1", locale: "en"}]},
    });
    expect(await run(withToken.db, makeMessaging())).toBe(1);
  });

  test("a throwing send is caught and the claim released", async () => {
    // A transient FCM failure must not abort the remaining recipients, and
    // must leave the reminder retryable.
    const {db, created, deleted} = makeLedgerDb({
      users: ACTIVE,
      tokens: {e1: [{id: "t1", locale: "en"}]},
    });
    const messaging = {
      sendEach: async () => {
        throw new Error("network");
      },
    };

    expect(await run(db, messaging)).toBe(0);
    expect(created).toHaveLength(1);
    expect(deleted).toHaveLength(1);
  });

  test("a failed release is swallowed rather than thrown", async () => {
    // The caller counts return values; throwing here would abort the sweep
    // over a cleanup failure that the next pass fixes anyway.
    const {db} = makeLedgerDb({
      users: ACTIVE,
      tokens: {e1: []},
      deleteThrows: new Error("release failed"),
    });

    await expect(run(db, makeMessaging())).resolves.toBe(0);
  });

  test("a ledger create failure that is NOT already-exists sends nothing",
      async () => {
        // Fail closed: with no claim there is no at-most-once guarantee, so
        // pushing anyway could deliver the same reminder every 5 minutes.
        const {db} = makeLedgerDb({
          users: ACTIVE,
          tokens: {e1: [{id: "t1", locale: "en"}]},
          createThrows: new Error("unavailable"),
        });
        const messaging = makeMessaging();

        expect(await run(db, messaging)).toBe(0);
        expect(messaging.sent).toEqual([]);
      });

  test("an inactive recipient gets nothing and costs no ledger write",
      async () => {
        // `_canReachRecipient` is asked before the claim, so a filtered
        // recipient no longer pays 2 writes + 2 reads on every one of the 24
        // sweep runs its overdue window spans.
        const {db, created, deleted} = makeLedgerDb({
          users: {e1: {role: "employee", status: "disabled"}},
          tokens: {e1: [{id: "t1", locale: "en"}]},
        });
        const messaging = makeMessaging();

        expect(await run(db, messaging)).toBe(0);
        expect(messaging.sent).toEqual([]);
        expect(created).toEqual([]);
        expect(deleted).toEqual([]);
      });

  test("it works when deps carry no logger", async () => {
    // Every log call is `if (logger)`-guarded because some call sites pass
    // deps without one; a bare `logger.warn` would turn a release failure
    // into a TypeError that escapes the sweep.
    const {db} = makeLedgerDb({users: ACTIVE, tokens: {e1: []}});
    const res = await deliverRecipientOnce(
        {db, messaging: makeMessaging(), now: NOW}, opts());
    expect(res).toBe(0);
  });
});

describe("handleAppointmentWrite per-recipient isolation", () => {
  // This trigger is registered WITHOUT `retry: true` ("a duplicate push is
  // worse than a rare missed one"), so a throw that escapes the recipient
  // loop drops the remaining assignees permanently — nothing retries them.
  const threeCrew = {
    users: {
      e1: {role: "employee", status: "active"},
      e2: {role: "employee", status: "active"},
      e3: {role: "employee", status: "active"},
    },
    tokens: {
      e1: [{id: "t1", locale: "en"}],
      e2: [{id: "t2", locale: "en"}],
      e3: [{id: "t3", locale: "en"}],
    },
  };

  const assignAll = (db, messaging) => handleAppointmentWrite(
      "appt1",
      null,
      {employeeIds: ["e1", "e2", "e3"], startTime: future(3 * HOUR)},
      {db, messaging, now: NOW, logger: silentLogger},
  );

  test("a failed send still notifies the remaining crew", async () => {
    const {db} = makeDb(threeCrew);
    const sent = [];
    let calls = 0;
    const messaging = {
      sent,
      sendEach: async (messages) => {
        calls += 1;
        // The first recipient's send rejects, as a transient FCM failure
        // does. `messaging.sendEach` sits outside `sendToEmployee`'s own
        // try, so this reaches the loop.
        if (calls === 1) throw new Error("fcm unavailable");
        sent.push(...messages);
        return {responses: messages.map(() => ({success: true}))};
      },
    };

    const res = await assignAll(db, messaging);

    // Two of three delivered rather than the whole event being dropped.
    expect(res).toEqual({events: 3, sent: 2});
    expect(sent.map((m) => m.token).sort()).toEqual(["t2", "t3"]);
  });

  test("a failed recipient read still notifies the rest", async () => {
    // `_loadRecipient` does a users read plus a tokens read; either can
    // reject, and it sits above the send in the same loop body.
    const {db} = makeDb(threeCrew);
    const broken = {
      ...db,
      collection: (name) => {
        const col = db.collection(name);
        if (name !== "users") return col;
        return {
          ...col,
          doc: (id) => id === "e1" ?
            {get: async () => {
              throw new Error("firestore unavailable");
            }} :
            col.doc(id),
        };
      },
    };
    const messaging = makeMessaging();

    const res = await assignAll(broken, messaging);

    expect(res).toEqual({events: 3, sent: 2});
    expect(messaging.sent.map((m) => m.token).sort()).toEqual(["t2", "t3"]);
  });

  test("the failure is logged, not swallowed", async () => {
    const {db} = makeDb(threeCrew);
    const warnings = [];
    const logger = {
      warn: (msg, ctx) => warnings.push({msg, ctx}),
      info: () => {},
      error: () => {},
    };
    let calls = 0;
    const messaging = {
      sent: [],
      sendEach: async (messages) => {
        calls += 1;
        if (calls === 1) throw new Error("fcm unavailable");
        return {responses: messages.map(() => ({success: true}))};
      },
    };

    await handleAppointmentWrite(
        "appt1",
        null,
        {employeeIds: ["e1", "e2", "e3"], startTime: future(3 * HOUR)},
        {db, messaging, now: NOW, logger},
    );

    // A dropped push that logs nothing is invisible in Crashlytics.
    const hit = warnings.find((w) => w.msg.includes("recipient failed"));
    expect(hit).toBeDefined();
    expect(hit.ctx.employeeDocId).toBe("e1");
    expect(hit.ctx.id).toBe("appt1");
  });
});
