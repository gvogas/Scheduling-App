"use strict";

const {
  isLastDayOfBusinessMonth,
  selectMonthEndOverdue,
  MONTH_END_REVIEW_MAX,
  MONTH_END_SCAN_MAX,
} = require("../notification_policy");
const {buildOverdueReviewMessage} = require("../notification_messages");
const {
  runMonthEndOverdueReview,
  sendToActiveAdmins,
} = require("../notification_utils");

/**
 * An instant given as Toronto wall-clock parts, via the zone's offset then.
 * @param {string} iso Local `YYYY-MM-DDTHH:mm` in America/Toronto.
 * @return {!Date}
 */
function toronto(iso) {
  const naive = new Date(`${iso}:00Z`);
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Toronto",
    hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(naive).reduce((acc, p) => {
    acc[p.type] = p.value;
    return acc;
  }, {});
  const asUtc = Date.UTC(Number(parts.year), Number(parts.month) - 1,
      Number(parts.day), Number(parts.hour), Number(parts.minute),
      Number(parts.second));
  return new Date(naive.getTime() - (asUtc - naive.getTime()));
}

describe("isLastDayOfBusinessMonth", () => {
  test.each([
    ["2026-01-31T18:00", true],
    ["2026-01-30T18:00", false],
    ["2026-02-28T18:00", true],
    ["2028-02-28T18:00", false],
    ["2028-02-29T18:00", true],
    ["2026-04-30T18:00", true],
    ["2026-04-29T18:00", false],
    ["2026-09-30T18:00", true],
    ["2026-12-31T18:00", true],
    ["2026-12-30T18:00", false],
  ])("%s -> %s", (iso, expected) => {
    expect(isLastDayOfBusinessMonth(toronto(iso))).toBe(expected);
  });

  test("DST spring-forward day (2026-03-08) is not a month end", () => {
    expect(isLastDayOfBusinessMonth(toronto("2026-03-08T18:00"))).toBe(false);
  });

  test("DST fall-back day (2026-10-31 is before the 11-01 shift)", () => {
    expect(isLastDayOfBusinessMonth(toronto("2026-10-31T23:59"))).toBe(true);
    expect(isLastDayOfBusinessMonth(toronto("2026-11-01T00:00"))).toBe(false);
  });

  test("zone boundary: 23:59 on the 31st is, 00:00 on the 1st is not", () => {
    expect(isLastDayOfBusinessMonth(toronto("2026-08-31T23:59"))).toBe(true);
    expect(isLastDayOfBusinessMonth(toronto("2026-09-01T00:00"))).toBe(false);
  });

  test("UTC already in the next month still reads Toronto's day", () => {
    // 2026-09-01T02:00Z is 22:00 on Aug 31 in Toronto.
    expect(isLastDayOfBusinessMonth(new Date("2026-09-01T02:00:00Z")))
        .toBe(true);
  });

  test("an unusable now is never a month end", () => {
    expect(isLastDayOfBusinessMonth(undefined)).toBe(false);
    expect(isLastDayOfBusinessMonth(new Date(NaN))).toBe(false);
  });
});

describe("selectMonthEndOverdue", () => {
  const now = new Date("2026-09-30T22:00:00Z");
  const ended = (daysAgo) =>
    new Date(now.getTime() - daysAgo * 24 * 60 * 60 * 1000);

  test("includes an open job of ANY age — no 2 h floor", () => {
    const out = selectMonthEndOverdue([
      {id: "a", status: "pending", endTime: ended(0.01)},
      {id: "b", status: "in_progress", endTime: ended(400)},
    ], now);
    expect(out.map((r) => r.id)).toEqual(["a", "b"]);
  });

  test("excludes personal blocks and time off", () => {
    const out = selectMonthEndOverdue([
      {id: "p", status: "pending", endTime: ended(3), isPersonal: true},
      {id: "t", status: "pending", endTime: ended(3), isPersonal: true,
        isDayOff: true},
    ], now);
    expect(out).toEqual([]);
  });

  test("excludes a missing or unparseable endTime", () => {
    const out = selectMonthEndOverdue([
      {id: "m", status: "pending"},
      {id: "u", status: "pending", endTime: "not a date"},
    ], now);
    expect(out).toEqual([]);
  });

  test("excludes terminal statuses and a job not yet ended", () => {
    const out = selectMonthEndOverdue([
      {id: "d", status: "done", endTime: ended(3)},
      {id: "c", status: "cancelled", endTime: ended(3)},
      {id: "f", status: "pending", endTime: ended(-1)},
    ], now);
    expect(out).toEqual([]);
  });

  test("an endTime exactly at now counts", () => {
    expect(selectMonthEndOverdue(
        [{id: "x", status: "pending", endTime: now}], now)).toHaveLength(1);
  });
});

describe("buildOverdueReviewMessage", () => {
  const now = new Date("2026-09-30T22:00:00Z");

  test("EN plural", () => {
    expect(buildOverdueReviewMessage(5, false, now, "en")).toEqual({
      title: "5 jobs still open",
      body: "They ended without being closed. " +
          "Review them before September wraps up.",
    });
  });

  test("EN singular", () => {
    expect(buildOverdueReviewMessage(1, false, now, "en")).toEqual({
      title: "1 job still open",
      body: "It ended without being closed. " +
          "Review it before September wraps up.",
    });
  });

  test("FR plural", () => {
    expect(buildOverdueReviewMessage(5, false, now, "fr")).toEqual({
      title: "5 visites encore ouvertes",
      body: "Elles se sont terminées sans être fermées. " +
          "Passez-les en revue avant la fin de septembre.",
    });
  });

  test("FR singular", () => {
    expect(buildOverdueReviewMessage(1, false, now, "fr")).toEqual({
      title: "1 visite encore ouverte",
      body: "Elle s'est terminée sans être fermée. " +
          "Passez-la en revue avant la fin de septembre.",
    });
  });

  test("FR elides de before a vowel month", () => {
    const april = new Date("2026-04-30T22:00:00Z");
    expect(buildOverdueReviewMessage(2, false, april, "fr").body)
        .toContain("avant la fin d'avril.");
  });

  test("at the cap both locales say 1000+", () => {
    expect(buildOverdueReviewMessage(MONTH_END_REVIEW_MAX, true, now, "en")
        .title).toBe("1000+ jobs still open");
    expect(buildOverdueReviewMessage(MONTH_END_REVIEW_MAX, true, now, "fr")
        .title).toBe("1000+ visites encore ouvertes");
  });

  test("the cap is 1000", () => {
    expect(MONTH_END_REVIEW_MAX).toBe(1000);
  });
});

/**
 * A Firestore stand-in that APPLIES `==` filters on users and returns the
 * appointment docs for the one scan query.
 * @param {{users: !Array<!Object>, appointments: !Array<!Object>}} data
 * @param {!Object} seen Collects the appointment query shape.
 * @return {!Object}
 */
function fakeDb(data, seen) {
  return {
    collection: (name) => {
      const filters = [];
      let limitN = Infinity;
      const q = {
        where: (field, op, value) => {
          filters.push([field, op, value]);
          return q;
        },
        orderBy: (field, dir) => {
          seen.orderBy = [field, dir];
          return q;
        },
        limit: (n) => {
          limitN = n;
          return q;
        },
        get: async () => {
          if (name === "appointments") {
            seen.filters = filters;
            seen.limit = limitN;
            const docs = data.appointments.slice(0, limitN).map((r) => ({
              id: r.id, data: () => r,
            }));
            return {docs, size: docs.length};
          }
          const docs = data.users
              .filter((u) => filters.every(([f, op, v]) =>
                op === "==" ? u[f] === v : true))
              .slice(0, limitN)
              .map((u) => ({id: u.id, data: () => u}));
          return {docs, size: docs.length};
        },
      };
      return q;
    },
  };
}

describe("runMonthEndOverdueReview", () => {
  const lastDay = new Date("2026-09-30T22:00:00Z");
  const notLastDay = new Date("2026-09-29T22:00:00Z");
  const openJob = (id) => ({
    id, status: "pending", endTime: new Date("2026-07-22T15:00:00Z"),
  });
  let logger;
  let sent;
  const send = async (_deps, docId, data, buildMsg) => {
    sent.push({docId, data, msg: buildMsg("en")});
    return 1;
  };

  beforeEach(() => {
    sent = [];
    logger = {info: jest.fn(), warn: jest.fn()};
  });

  const users = [
    {id: "paul", role: "admin", status: "active", monthEndReviewPush: true},
    {id: "evans", role: "admin", status: "active"},
    {id: "george", role: "admin", status: "active", monthEndReviewPush: false},
    {id: "tech", role: "employee", status: "active", monthEndReviewPush: true},
    {id: "gone", role: "admin", status: "disabled", monthEndReviewPush: true},
  ];

  test("does nothing on any other day, without reading", async () => {
    const seen = {};
    const db = fakeDb({users, appointments: [openJob("a")]}, seen);
    const out = await runMonthEndOverdueReview(
        {db, logger, now: notLastDay}, {sendToEmployee: send});
    expect(out).toEqual({count: 0, recipients: 0});
    expect(seen.filters).toBeUndefined();
    expect(sent).toEqual([]);
  });

  test("sends only to active admins whose switch is on", async () => {
    const db = fakeDb({users, appointments: [openJob("a"), openJob("b")]}, {});
    const out = await runMonthEndOverdueReview(
        {db, logger, now: lastDay}, {sendToEmployee: send});
    expect(sent.map((s) => s.docId)).toEqual(["paul"]);
    expect(out).toEqual({count: 2, recipients: 1});
    expect(logger.info).toHaveBeenCalledWith(
        "monthEndReview: sent", {count: 2, recipients: 1});
  });

  test("the payload is {kind, count} with NO appointmentId", async () => {
    const db = fakeDb({users, appointments: [openJob("a")]}, {});
    await runMonthEndOverdueReview(
        {db, logger, now: lastDay}, {sendToEmployee: send});
    expect(sent[0].data).toEqual({kind: "overdueReview", count: "1"});
    expect(sent[0].msg.title).toBe("1 job still open");
  });

  test("zero open jobs sends nothing", async () => {
    const db = fakeDb({
      users,
      appointments: [{...openJob("p"), isPersonal: true}],
    }, {});
    const out = await runMonthEndOverdueReview(
        {db, logger, now: lastDay}, {sendToEmployee: send});
    expect(sent).toEqual([]);
    expect(out).toEqual({count: 0, recipients: 0});
  });

  test("an empty recipient list still logs, so a silent run is visible",
      async () => {
        const db = fakeDb({
          users: users.filter((u) => u.id !== "paul"),
          appointments: [openJob("a")],
        }, {});
        await runMonthEndOverdueReview(
            {db, logger, now: lastDay}, {sendToEmployee: send});
        expect(sent).toEqual([]);
        expect(logger.info).toHaveBeenCalledWith(
            "monthEndReview: sent", {count: 1, recipients: 0});
      });

  test("queries open statuses by endTime DESC, scan-capped", async () => {
    const seen = {};
    const db = fakeDb({users, appointments: [openJob("a")]}, seen);
    await runMonthEndOverdueReview(
        {db, logger, now: lastDay}, {sendToEmployee: send});
    expect(seen.filters[0][0]).toBe("status");
    expect(seen.filters[0][1]).toBe("in");
    expect(seen.filters[0][2]).toEqual(
        expect.arrayContaining(["pending", "in_progress"]));
    expect(seen.orderBy).toEqual(["endTime", "desc"]);
    expect(seen.limit).toBe(MONTH_END_SCAN_MAX);
  });

  test("at the display cap the push says 1000+", async () => {
    const many = Array.from({length: MONTH_END_REVIEW_MAX + 5},
        (_, i) => openJob(`j${i}`));
    const db = fakeDb({users, appointments: many}, {});
    const out = await runMonthEndOverdueReview(
        {db, logger, now: lastDay}, {sendToEmployee: send});
    expect(sent[0].data.count).toBe("1000+");
    expect(sent[0].msg.title).toBe("1000+ jobs still open");
    expect(out.count).toBe(MONTH_END_REVIEW_MAX);
  });

  test("personal rows past the display cap do not consume it", async () => {
    const personal = Array.from({length: MONTH_END_REVIEW_MAX + 200},
        (_, i) => ({...openJob(`p${i}`), isPersonal: true}));
    const db = fakeDb(
        {users, appointments: [...personal, openJob("a"), openJob("b")]}, {});
    await runMonthEndOverdueReview(
        {db, logger, now: lastDay}, {sendToEmployee: send});
    expect(sent[0].data.count).toBe("2");
  });

  test("at the raw scan cap the count reads N+ and the scan warns",
      async () => {
        const rows = [
          openJob("a"),
          openJob("b"),
          ...Array.from({length: MONTH_END_SCAN_MAX},
              (_, i) => ({...openJob(`p${i}`), isPersonal: true})),
        ];
        const db = fakeDb({users, appointments: rows}, {});
        await runMonthEndOverdueReview(
            {db, logger, now: lastDay}, {sendToEmployee: send});
        expect(sent[0].data.count).toBe("2+");
        expect(logger.warn).toHaveBeenCalledWith(
            expect.stringContaining(
                "runMonthEndOverdueReview: candidate cap hit"),
            {cap: MONTH_END_SCAN_MAX});
      });
});

describe("sendToActiveAdmins includeUser", () => {
  test("returns the number of admins it sent to after filtering",
      async () => {
        const db = fakeDb({
          users: [
            {id: "a", role: "admin", status: "active", flag: true},
            {id: "b", role: "admin", status: "active"},
          ],
          appointments: [],
        }, {});
        const ids = [];
        const n = await sendToActiveAdmins(
            {db, logger: {warn: jest.fn()}},
            {kind: "x"},
            () => ({title: "t", body: "b"}),
            {
              includeUser: (u) => u.flag === true,
              sendToEmployee: async (_d, id) => {
                ids.push(id);
                return 1;
              },
            },
        );
        expect(ids).toEqual(["a"]);
        expect(n).toBe(1);
      });
});
