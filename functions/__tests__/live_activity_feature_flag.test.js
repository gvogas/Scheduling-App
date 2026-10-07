"use strict";

jest.mock("../apns_client", () => ({sendLiveActivityPush: jest.fn()}));
jest.mock("../live_activity_registry", () => ({
  listPushToStartTokens: jest.fn(),
  listUpdateTokens: jest.fn(),
  deleteActivityToken: jest.fn(),
  writeCardMarker: jest.fn(),
  readCardMarker: jest.fn(),
  setCardStart: jest.fn(),
  clearCardMarker: jest.fn(),
}));

const {sendLiveActivityPush} = require("../apns_client");
const registry = require("../live_activity_registry");
const {
  startLiveActivity,
  updateLiveActivity,
  endLiveActivity,
} = require("../live_activity_dispatch");

const AUTH = {authKey: "-----KEY-----", keyId: "K1", teamId: "T1"};
const NOW = new Date("2026-07-19T11:30:00Z");
const CTX = {clientName: "Ada", address: "14 Elm St",
  startTime: new Date("2026-07-19T12:00:00Z")};
const ROW = {token: "tok-1", locale: "en", kind: "update",
  employeeDocId: "emp1", ref: {id: "act1"}};

/**
 * @param {boolean} on
 * @return {!Object}
 */
function deps(on) {
  const employee = {exists: true, data: () => ({colorValue: 1})};
  return {
    db: {collection: () => ({doc: () => ({get: async () => employee})})},
    logger: {warn: jest.fn(), info: jest.fn()},
    apnsAuth: AUTH,
    featureFlags: async () => ({feature_live_activities: on}),
  };
}

beforeEach(() => {
  jest.clearAllMocks();
  sendLiveActivityPush.mockResolvedValue({ok: true, gone: false});
  registry.listPushToStartTokens.mockResolvedValue([ROW]);
  registry.listUpdateTokens.mockResolvedValue([ROW]);
  registry.writeCardMarker.mockResolvedValue(true);
  registry.setCardStart.mockResolvedValue(true);
  registry.readCardMarker.mockResolvedValue(
      {employeeDocId: "emp1", appointmentId: "appt1", phase: "travel"});
});

test("paused: start sends nothing and deletes nothing", async () => {
  const started = await startLiveActivity(deps(false), {
    appointmentId: "appt1", employeeDocId: "emp1", ctx: CTX, nowDate: NOW,
  });
  expect(started).toBe(0);
  expect(sendLiveActivityPush).not.toHaveBeenCalled();
  expect(registry.deleteActivityToken).not.toHaveBeenCalled();
  expect(registry.writeCardMarker).not.toHaveBeenCalled();
});

test("paused: update sends nothing and deletes nothing", async () => {
  const updated = await updateLiveActivity(deps(false), {
    appointmentId: "appt1", employeeDocId: "emp1", ctx: CTX, nowDate: NOW,
  });
  expect(updated).toBe(0);
  expect(sendLiveActivityPush).not.toHaveBeenCalled();
  expect(registry.deleteActivityToken).not.toHaveBeenCalled();
  expect(registry.setCardStart).not.toHaveBeenCalled();
});

test("paused: end sends nothing and keeps the token and marker", async () => {
  const ended = await endLiveActivity(deps(false), {
    appointmentId: "appt1", employeeDocId: "emp1", ctx: CTX, nowDate: NOW,
  });
  expect(ended).toBe(0);
  expect(sendLiveActivityPush).not.toHaveBeenCalled();
  expect(registry.deleteActivityToken).not.toHaveBeenCalled();
  expect(registry.clearCardMarker).not.toHaveBeenCalled();
});

test("on: end sends and drops the token", async () => {
  await endLiveActivity(deps(true), {
    appointmentId: "appt1", employeeDocId: "emp1", ctx: CTX, nowDate: NOW,
  });
  expect(sendLiveActivityPush).toHaveBeenCalledTimes(1);
  expect(registry.deleteActivityToken).toHaveBeenCalled();
});

test("on: a push is sent as before", async () => {
  await updateLiveActivity(deps(true), {
    appointmentId: "appt1", employeeDocId: "emp1", ctx: CTX, nowDate: NOW,
  });
  expect(sendLiveActivityPush).toHaveBeenCalledTimes(1);
});
