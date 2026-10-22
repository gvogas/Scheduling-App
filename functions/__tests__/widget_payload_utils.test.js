"use strict";

/**
 * Unit tests for the server-side widget payload builder. These mirror the
 * Dart widget_payload_test.dart cases (plus the Toronto day-boundary one) so
 * both builders and the Swift decoder stay in lockstep.
 */

const {
  buildWidgetPayload,
  serializeWidgetJob,
} = require("../widget_payload_utils");

// Noon Toronto (EDT -4) on Wed 2026-07-08.
const NOW = new Date("2026-07-08T16:00:00.000Z");

const at = (iso) => new Date(iso);
const appt = (id, startIso, extra) => ({
  id,
  title: `Job ${id}`,
  clientName: "Client",
  startTime: at(startIso),
  endTime: at(new Date(at(startIso).getTime() + 3600000).toISOString()),
  status: "pending",
  ...(extra || {}),
});

describe("buildWidgetPayload", () => {
  test("todayJobs are future, non-terminal, and sorted", () => {
    const payload = buildWidgetPayload([
      appt("past", "2026-07-08T13:00:00.000Z"),
      appt("later", "2026-07-08T20:00:00.000Z"),
      appt("soon", "2026-07-08T18:00:00.000Z"),
      appt("done", "2026-07-08T19:00:00.000Z", {status: "done"}),
      appt("tomorrow", "2026-07-09T13:00:00.000Z"),
    ], NOW);

    expect(payload.todayJobs.map((j) => j.id)).toEqual(["soon", "later"]);
    expect(payload.tomorrowJobs.map((j) => j.id)).toEqual(["tomorrow"]);
    // an open job today means no rollover yet.
    expect(payload.rolloverAt).toBeNull();
  });

  test("an all-day block stays in today until its 23:59 end", () => {
    // Midnight → 23:59 Toronto on 2026-07-08 — the start is already past by
    // NOW, so a start-time test would drop it from today entirely.
    const allDay = appt("vacation", "2026-07-08T04:00:00.000Z", {
      endTime: at("2026-07-09T03:59:00.000Z"),
      isAllDay: true,
    });
    const payload = buildWidgetPayload([allDay], NOW);
    expect(payload.todayJobs.map((j) => j.id)).toEqual(["vacation"]);
    expect(payload.todayJobs[0].isAllDay).toBe(true);
    // Still open, so no rollover.
    expect(payload.rolloverAt).toBeNull();
  });

  test("each job carries its id and a …Z startTime for the deep link", () => {
    const payload = buildWidgetPayload([
      appt("soon", "2026-07-08T18:00:00.000Z"),
    ], NOW);
    expect(payload.todayJobs[0].id).toBe("soon");
    expect(payload.todayJobs[0].startTime).toBe("2026-07-08T18:00:00.000Z");
  });

  test("rolloverAt is last endTime + 1h once today is all complete", () => {
    const payload = buildWidgetPayload([
      appt("done", "2026-07-08T13:00:00.000Z", {
        status: "done",
        endTime: at("2026-07-08T14:00:00.000Z"),
      }),
      appt("tmwLater", "2026-07-09T18:00:00.000Z"),
      appt("tmwFirst", "2026-07-09T13:00:00.000Z"),
    ], NOW);
    expect(payload.rolloverAt).toBe("2026-07-08T15:00:00.000Z");
    expect(payload.todayJobs).toHaveLength(0);
    expect(payload.tomorrowJobs.map((j) => j.id)).toEqual(
        ["tmwFirst", "tmwLater"]);
    expect(payload.todayDate).toBe("2026-07-08T04:00:00.000Z");
    expect(payload.tomorrowDate).toBe("2026-07-09T04:00:00.000Z");
  });

  test("empty / all-cancelled today rolls over at start of today", () => {
    expect(buildWidgetPayload([], NOW).rolloverAt)
        .toBe("2026-07-08T04:00:00.000Z");
    const cancelled = buildWidgetPayload([
      appt("cxl", "2026-07-08T18:00:00.000Z", {status: "cancelled"}),
    ], NOW);
    expect(cancelled.rolloverAt).toBe("2026-07-08T04:00:00.000Z");
    expect(cancelled.todayJobs).toHaveLength(0);
  });

  test("the today cutoff is Toronto midnight, not UTC", () => {
    // 23:00 Toronto today (03:00Z the next day) still counts as today. 01:00
    // Toronto tomorrow (05:00Z) counts as tomorrow.
    const payload = buildWidgetPayload([
      appt("tonight", "2026-07-09T03:00:00.000Z"),
      appt("after-midnight", "2026-07-09T05:00:00.000Z"),
    ], NOW);
    expect(payload.todayJobs.map((j) => j.id)).toEqual(["tonight"]);
    expect(payload.tomorrowJobs.map((j) => j.id)).toEqual(["after-midnight"]);
  });

  test("locale is carried through", () => {
    expect(buildWidgetPayload([], NOW, "fr").locale).toBe("fr");
    expect(buildWidgetPayload([], NOW).locale).toBe("en");
  });

  // Multi-day, mirroring the Dart widget_payload_test.dart cases exactly.
  // August is EDT, so Toronto is UTC-4 throughout.
  const AUG3_0700 = new Date("2026-08-03T11:00:00.000Z");

  test("a job that started earlier and runs through today is listed", () => {
    const payload = buildWidgetPayload([
      appt("multi", "2026-08-01T13:00:00.000Z", { // Aug 1 09:00
        endTime: at("2026-08-05T21:00:00.000Z"), // Aug 5 17:00
      }),
    ], AUG3_0700);

    expect(payload.todayJobs).toHaveLength(1);
    const job = payload.todayJobs[0];
    expect(job.dayIndex).toBe(3);
    expect(job.dayCount).toBe(5);
    // The clock the widget shows must be TODAY's window, not Aug 1's.
    expect(job.startTime).toBe("2026-08-03T13:00:00.000Z");
  });

  test("a run continuing tomorrow is listed there with tomorrow's window",
      () => {
        const payload = buildWidgetPayload([
          appt("multi", "2026-08-01T13:00:00.000Z", {
            endTime: at("2026-08-05T21:00:00.000Z"),
          }),
        ], AUG3_0700);

        expect(payload.tomorrowJobs).toHaveLength(1);
        expect(payload.tomorrowJobs[0].dayIndex).toBe(4);
        expect(payload.tomorrowJobs[0].startTime)
            .toBe("2026-08-04T13:00:00.000Z");
      });

  test("a night shift is listed on the evening it starts, not after", () => {
    const night = () => appt("night", "2026-08-02T02:00:00.000Z", {
      endTime: at("2026-08-04T10:00:00.000Z"), // Aug 4 06:00
    });

    // Aug 3 is the last night the crew starts.
    expect(buildWidgetPayload([night()], AUG3_0700).todayJobs).toHaveLength(1);
    // Aug 4 is only the morning it ends — nobody starts work.
    const after = buildWidgetPayload(
        [night()], new Date("2026-08-04T11:00:00.000Z"));
    expect(after.todayJobs).toHaveLength(0);
  });

  test("a single-day job carries no day counter", () => {
    const payload = buildWidgetPayload([
      appt("one", "2026-08-03T12:30:00.000Z"), // Aug 3 08:30
    ], AUG3_0700);

    const job = payload.todayJobs[0];
    expect(job.dayIndex).toBeUndefined();
    expect(job.dayCount).toBeUndefined();
  });

  test("rollover uses today's window end, not the run's final day", () => {
    const payload = buildWidgetPayload([
      appt("multi", "2026-08-01T13:00:00.000Z", {
        endTime: at("2026-08-05T21:00:00.000Z"),
        status: "done",
      }),
    ], AUG3_0700);

    // Today's window ends Aug 3 17:00 Toronto, so rollover is 18:00 — not an
    // instant two days out at the end of the whole run.
    expect(payload.rolloverAt).toBe("2026-08-03T22:00:00.000Z");
  });
});

describe("serializeWidgetJob", () => {
  // A single-day slice around a record, matching what sliceForDay returns.
  const slice = (record, windowStartIso, extra) => ({
    record,
    dayIndex: 1,
    dayCount: 1,
    windowStartMs: at(windowStartIso || "2026-07-08T18:00:00.000Z"),
    windowEndMs: at("2026-07-08T19:00:00.000Z"),
    isOvernight: false,
    isMultiDay: false,
    ...(extra || {}),
  });

  test("null string fields become empty strings (Swift non-optional decode)",
      () => {
        const job = serializeWidgetJob(slice({
          id: "a1",
          clientName: null,
          title: null,
          address: null,
          status: null,
        }));
        expect(job).toEqual({
          id: "a1",
          startTime: "2026-07-08T18:00:00.000Z",
          endTime: "2026-07-08T19:00:00.000Z",
          clientName: "",
          title: "",
          address: "",
          status: "pending",
          isAllDay: false,
        });
      });

  test("isAllDay is emitted as a real boolean, never null", () => {
    expect(serializeWidgetJob(slice({id: "a1", isAllDay: true})).isAllDay)
        .toBe(true);
    expect(serializeWidgetJob(slice({id: "a1"})).isAllDay).toBe(false);
  });

  test("the counter is omitted entirely for a single-day job", () => {
    const job = serializeWidgetJob(slice({id: "a1"}));
    expect("dayIndex" in job).toBe(false);
    expect("dayCount" in job).toBe(false);
  });

  test("a multi-day slice carries its counter", () => {
    const job = serializeWidgetJob(slice({id: "a1"}, null, {
      dayIndex: 2,
      dayCount: 5,
      isMultiDay: true,
    }));
    expect(job.dayIndex).toBe(2);
    expect(job.dayCount).toBe(5);
  });
});
