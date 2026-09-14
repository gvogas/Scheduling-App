"use strict";

/**
 * Rider-isolation tests for the two SCHEDULED functions in `notifications.js`.
 *
 * The existing `notifications.test.js` asserts against the module's SOURCE
 * TEXT with `fs.readFileSync` + regexes, so no handler had ever actually been
 * invoked (0% branch / 0% func). These drive the real handlers.
 *
 * What they pin is the file's own stated safety argument for folding six Cloud
 * Scheduler jobs down to three (the free allowance):
 *
 *   "EACH RIDER IS ISOLATED IN ITS OWN try/catch, and that is the whole safety
 *    argument for merging ... neither can skip the other."
 *
 * Collapse two riders into one `try` and a single bad appointment silently
 * kills the Live Activity TTL prune AND the whole daily Wave drain+import —
 * while Cloud Scheduler still reports the run green. Nothing but a test can
 * catch that, because the failure mode IS "no error surfaced".
 */

jest.mock("firebase-admin/firestore");
jest.mock("firebase-admin/messaging");
jest.mock("firebase-functions/logger", () => ({
  info: jest.fn(),
  warn: jest.fn(),
  debug: jest.fn(),
  error: jest.fn(),
}));
jest.mock("../notification_utils", () => ({
  handleAppointmentWrite: jest.fn(),
  runDailyDigest: jest.fn(),
  runOverduePromptSweep: jest.fn(),
  runMonthEndOverdueReview: jest.fn(),
}));
jest.mock("../travel_utils", () => ({
  runTravelAwareReminderSweep: jest.fn(),
}));
jest.mock("../live_activity_registry", () => ({
  pruneExpiredActivityTokens: jest.fn(),
  pruneExpiredCardMarkers: jest.fn(),
}));
jest.mock("../wave/triggers", () => ({
  runWaveDaily: jest.fn(),
}));

const {getFirestore} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");
const policy = require("../notification_utils");
const travel = require("../travel_utils");
const registry = require("../live_activity_registry");
const waveTriggers = require("../wave/triggers");

const {
  sendDailyJobDigest,
  sendUpcomingJobReminders,
} = require("../notifications");

beforeEach(() => {
  jest.clearAllMocks();
  getFirestore.mockReturnValue({});
  getMessaging.mockReturnValue({});
  policy.runDailyDigest.mockResolvedValue(undefined);
  policy.runOverduePromptSweep.mockResolvedValue(undefined);
  policy.runMonthEndOverdueReview.mockResolvedValue({count: 0, recipients: 0});
  travel.runTravelAwareReminderSweep.mockResolvedValue(undefined);
  registry.pruneExpiredActivityTokens.mockResolvedValue({pruned: 0});
  registry.pruneExpiredCardMarkers.mockResolvedValue({pruned: 0});
  waveTriggers.runWaveDaily.mockResolvedValue(undefined);
});

describe("sendDailyJobDigest riders", () => {
  test("the happy path runs the digest and all riders, in order", async () => {
    await sendDailyJobDigest.run({});

    expect(policy.runDailyDigest).toHaveBeenCalledTimes(1);
    expect(registry.pruneExpiredActivityTokens).toHaveBeenCalledTimes(1);
    expect(policy.runMonthEndOverdueReview).toHaveBeenCalledTimes(1);
    expect(waveTriggers.runWaveDaily).toHaveBeenCalledTimes(1);
    // The digest is the only time-sensitive step, so it must go first.
    expect(policy.runDailyDigest.mock.invocationCallOrder[0])
        .toBeLessThan(
            registry.pruneExpiredActivityTokens.mock.invocationCallOrder[0]);
    expect(registry.pruneExpiredActivityTokens.mock.invocationCallOrder[0])
        .toBeLessThan(
            policy.runMonthEndOverdueReview.mock.invocationCallOrder[0]);
  });

  test("the month-end review runs BEFORE the Wave rider", async () => {
    // All riders share one 540 s timeout and the Wave import once needed most
    // of it, so a rider below Wave could be killed on the evening it matters.
    await sendDailyJobDigest.run({});

    expect(policy.runMonthEndOverdueReview.mock.invocationCallOrder[0])
        .toBeLessThan(waveTriggers.runWaveDaily.mock.invocationCallOrder[0]);
  });

  test("a THROWING month-end review still runs the Wave rider", async () => {
    policy.runMonthEndOverdueReview.mockRejectedValue(new Error("review boom"));

    await expect(sendDailyJobDigest.run({})).resolves.toBeUndefined();

    expect(waveTriggers.runWaveDaily).toHaveBeenCalledTimes(1);
    expect(logger.warn).toHaveBeenCalledWith(
        "monthEndReview failed", expect.anything());
  });

  test("a THROWING digest or prune still runs the month-end review",
      async () => {
        policy.runDailyDigest.mockRejectedValue(new Error("a"));
        registry.pruneExpiredActivityTokens.mockRejectedValue(new Error("b"));

        await expect(sendDailyJobDigest.run({})).resolves.toBeUndefined();

        expect(policy.runMonthEndOverdueReview).toHaveBeenCalledTimes(1);
      });

  test("the month-end review gets Firestore-only deps", async () => {
    await sendDailyJobDigest.run({});

    const [deps] = policy.runMonthEndOverdueReview.mock.calls[0];
    expect(deps).toHaveProperty("db");
    expect(deps).not.toHaveProperty("apnsAuth");
  });

  test("a THROWING digest still runs both riders", async () => {
    // The exact regression the isolation exists to prevent: the digest fans
    // out with Promise.all, so one bad appointment rejects the whole batch.
    policy.runDailyDigest.mockRejectedValue(new Error("bad appointment"));

    await expect(sendDailyJobDigest.run({})).resolves.toBeUndefined();

    expect(registry.pruneExpiredActivityTokens).toHaveBeenCalledTimes(1);
    expect(waveTriggers.runWaveDaily).toHaveBeenCalledTimes(1);
    expect(logger.error).toHaveBeenCalledWith(
        "sendDailyJobDigest failed", expect.anything());
  });

  test("a THROWING TTL prune still runs the Wave rider", async () => {
    registry.pruneExpiredActivityTokens
        .mockRejectedValue(new Error("prune boom"));

    await expect(sendDailyJobDigest.run({})).resolves.toBeUndefined();

    expect(waveTriggers.runWaveDaily).toHaveBeenCalledTimes(1);
    expect(logger.warn).toHaveBeenCalledWith(
        "liveActivity: TTL prune failed", expect.anything());
  });

  test("a throwing card-marker prune does not take the Wave rider down",
      async () => {
        // The second half of rider 2 shares its try with the first; what must
        // not happen is rider 3 being skipped.
        registry.pruneExpiredCardMarkers
            .mockRejectedValue(new Error("marker boom"));

        await expect(sendDailyJobDigest.run({})).resolves.toBeUndefined();

        expect(waveTriggers.runWaveDaily).toHaveBeenCalledTimes(1);
      });

  test("a THROWING Wave rider never fails the invocation", async () => {
    // Belt-and-braces per the comment: runWaveDaily catches internally, so
    // this guards a future edit there from taking the digest down.
    waveTriggers.runWaveDaily.mockRejectedValue(new Error("wave boom"));

    await expect(sendDailyJobDigest.run({})).resolves.toBeUndefined();
    expect(logger.warn).toHaveBeenCalledWith(
        "runWaveDaily failed", expect.anything());
  });

  test("EVERY step failing still resolves", async () => {
    policy.runDailyDigest.mockRejectedValue(new Error("a"));
    registry.pruneExpiredActivityTokens.mockRejectedValue(new Error("b"));
    policy.runMonthEndOverdueReview.mockRejectedValue(new Error("d"));
    waveTriggers.runWaveDaily.mockRejectedValue(new Error("c"));

    await expect(sendDailyJobDigest.run({})).resolves.toBeUndefined();
  });

  test("a prune that removed nothing logs no info line", async () => {
    await sendDailyJobDigest.run({});
    expect(logger.info).not.toHaveBeenCalledWith(
        "liveActivity: TTL prune", expect.anything());
  });

  test("a prune that removed something reports both counts", async () => {
    registry.pruneExpiredActivityTokens.mockResolvedValue({pruned: 2});
    registry.pruneExpiredCardMarkers.mockResolvedValue({pruned: 3});

    await sendDailyJobDigest.run({});

    expect(logger.info).toHaveBeenCalledWith(
        "liveActivity: TTL prune", {tokens: 2, cards: 3});
  });
});

describe("sendUpcomingJobReminders riders", () => {
  test("the happy path runs the travel sweep then the overdue sweep",
      async () => {
        await sendUpcomingJobReminders.run({});

        expect(travel.runTravelAwareReminderSweep).toHaveBeenCalledTimes(1);
        expect(policy.runOverduePromptSweep).toHaveBeenCalledTimes(1);
        expect(travel.runTravelAwareReminderSweep.mock.invocationCallOrder[0])
            .toBeLessThan(
                policy.runOverduePromptSweep.mock.invocationCallOrder[0]);
      });

  test("a THROWING travel sweep still runs the overdue sweep", async () => {
    travel.runTravelAwareReminderSweep
        .mockRejectedValue(new Error("routes down"));

    await expect(sendUpcomingJobReminders.run({})).resolves.toBeUndefined();

    expect(policy.runOverduePromptSweep).toHaveBeenCalledTimes(1);
    expect(logger.error).toHaveBeenCalledWith(
        "sendUpcomingJobReminders failed", expect.anything());
  });

  test("a THROWING overdue sweep never fails the invocation", async () => {
    policy.runOverduePromptSweep.mockRejectedValue(new Error("overdue boom"));

    await expect(sendUpcomingJobReminders.run({})).resolves.toBeUndefined();
  });

  test("the overdue failure keeps the DELETED export's log label", async () => {
    // Deliberately still `sendOverdueJobPrompts`: it is a stable Crashlytics
    // search tag, and renaming it orphans every prior report of this failure.
    policy.runOverduePromptSweep.mockRejectedValue(new Error("boom"));

    await sendUpcomingJobReminders.run({});

    expect(logger.error).toHaveBeenCalledWith(
        "sendOverdueJobPrompts failed", expect.anything());
  });

  test("the overdue sweep gets Firestore-only deps, never the APNs auth",
      async () => {
        // `liveDeps()`, not `liveActivityDeps()` — a function that doesn't
        // push cards must not read the APNs secrets.
        await sendUpcomingJobReminders.run({});

        const [deps] = policy.runOverduePromptSweep.mock.calls[0];
        expect(deps).not.toHaveProperty("apnsAuth");
        expect(deps).toHaveProperty("db");
      });
});
