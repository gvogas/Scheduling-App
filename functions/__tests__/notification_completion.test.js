"use strict";

/** The completion signal to the dispatcher (I11, 2026-09-01). */

const {isCrewCompletion} = require("../notification_policy");
const {buildJobCompletedMessage} = require("../notification_messages");
const {notifyAdminsOfCompletion} = require("../notification_utils");

const job = (over) => ({
  status: "pending",
  title: "Leak fix",
  clientName: "Acme",
  employeeIds: ["e1"],
  employeeNames: ["Marc"],
  ...over,
});

describe("isCrewCompletion", () => {
  test("a pending -> done transition counts", () => {
    expect(isCrewCompletion(job(), job({status: "done"}))).toBe(true);
  });

  test("the legacy completed alias counts too", () => {
    expect(isCrewCompletion(job(), job({status: "completed"}))).toBe(true);
  });

  test("a RE-SAVE of an already-done job is silent", () => {
    // Every write re-fires this trigger — a photo append, a client-edit
    // propagation, a recount's parent touch.
    expect(
        isCrewCompletion(job({status: "done"}), job({status: "done"})),
    ).toBe(false);
  });

  test("a CANCELLATION is not a completion", () => {
    // Usually the admin's own action, and telling somebody what they just did
    // is noise.
    expect(isCrewCompletion(job(), job({status: "cancelled"}))).toBe(false);
  });

  test("a personal block is not work", () => {
    expect(
        isCrewCompletion(
            job({isPersonal: true}),
            job({isPersonal: true, status: "done"}),
        ),
    ).toBe(false);
  });

  test("time off is not work either", () => {
    // And its completion is DERIVED — a day off completes itself at the end of
    // its last day and is never written as done — so a stored one is a legacy
    // or console row, which is exactly what must not page anybody.
    expect(
        isCrewCompletion(
            job({isPersonal: true, isDayOff: true}),
            job({isPersonal: true, isDayOff: true, status: "done"}),
        ),
    ).toBe(false);
  });

  test("a create is not a completion, even created as done", () => {
    expect(isCrewCompletion(null, job({status: "done"}))).toBe(false);
  });

  test("a delete is not a completion", () => {
    expect(isCrewCompletion(job({status: "done"}), null)).toBe(false);
  });

  test("a write stamping a FRESH op id is an admin write, not crew", () => {
    // The month-end review closes 60 jobs in one batch; that must page nobody.
    expect(
        isCrewCompletion(
            job({seriesOpId: "old"}),
            job({seriesOpId: "bulk-1", status: "done"}),
        ),
    ).toBe(false);
  });

  test("a crew mark-done keeps the stored op id, so it still counts", () => {
    expect(
        isCrewCompletion(
            job({seriesOpId: "old"}),
            job({seriesOpId: "old", status: "done"}),
        ),
    ).toBe(true);
  });
});

describe("buildJobCompletedMessage", () => {
  test("names who and what, in both languages", () => {
    expect(buildJobCompletedMessage("Marc", "Acme", "en").body)
        .toBe("Marc finished Acme.");
    expect(buildJobCompletedMessage("Marc", "Acme", "fr").body)
        .toContain("Marc");
  });

  test("falls back when the crew is unknown", () => {
    // An unassigned job has no name to speak; the job still does.
    expect(buildJobCompletedMessage("", "Acme", "en").body)
        .toBe("Acme was marked complete.");
  });

  test("falls back again when neither is known", () => {
    expect(buildJobCompletedMessage("", "", "en").body)
        .toBe("A job was marked complete.");
  });

  test("carries no address and no phone number", () => {
    // It reaches a Lock Screen. Client PII is exactly what must not sit there.
    const msg = buildJobCompletedMessage(
        "Marc", "Acme", "en",
    );
    expect(JSON.stringify(msg)).not.toMatch(/\d{3}/);
  });
});

describe("notifyAdminsOfCompletion", () => {
  /**
   * Firestore double returning a fixed admin roster.
   * @param {!Array<{id: string}>} admins Admin users docs.
   * @return {!Object}
   */
  const makeDb = (admins) => ({
    collection: () => ({
      where: function where() {
        return this;
      },
      limit: function limit() {
        return this;
      },
      get: async () => ({
        size: admins.length,
        docs: admins.map((a) => ({id: a.id, data: () => a})),
      }),
    }),
  });

  const deps = (admins, sent) => ({
    db: makeDb(admins),
    messaging: {},
    logger: {warn: jest.fn(), info: jest.fn()},
    // The fan-out calls the module's own sendToEmployee; intercept through the
    // messaging layer instead by recording what tokens it would resolve.
    __sent: sent,
  });

  test("does nothing at all when the write is not a completion", async () => {
    const d = deps([{id: "admin-1", role: "admin", status: "active"}]);
    let queried = false;
    d.db = {
      collection: () => {
        queried = true;
        return {where: () => ({}), limit: () => ({}), get: async () => ({})};
      },
    };

    await notifyAdminsOfCompletion("a1", job(), job(), d);

    expect(queried).toBe(false);
  });

  test("never throws, whatever the roster read does", async () => {
    // The completion is already committed.
    const d = {
      db: {
        collection: () => {
          throw new Error("unavailable");
        },
      },
      messaging: {},
      logger: {warn: jest.fn()},
    };

    await expect(
        notifyAdminsOfCompletion("a1", job(), job({status: "done"}), d),
    ).resolves.toBeUndefined();
    expect(d.logger.warn).toHaveBeenCalled();
  });
});
