"use strict";

/**
 * Pins the DEPLOYED function set.
 *
 * `index.js` is pure wiring, and the only signal anyone had on it was the
 * count `firebase deploy` prints — which is blind to a rename or a swap. The
 * repo has already been bitten by exactly that: a release where "the export
 * SET changed by 6 at an unchanged count of 25". A renamed export deploys as a
 * NEW function and silently retires the old one, taking its triggers with it.
 *
 * The literal below is the contract. Changing it is a deliberate act with a
 * deploy consequence — read `docs/DEPLOYMENT.md` before you do.
 */

// `index.js` registers a Storage trigger (`validateUploadedImage`), and
// `onObjectFinalized` resolves its bucket name at REGISTRATION time — with no
// `FIREBASE_CONFIG` it throws "Missing bucket name" on require. Set before the
// require so this suite needs no emulator.
process.env.FIREBASE_CONFIG = JSON.stringify({
  projectId: "schedulingapp-88727",
  storageBucket: "schedulingapp-88727.firebasestorage.app",
});
process.env.GCLOUD_PROJECT = "schedulingapp-88727";

const EXPECTED_EXPORTS = [
  "cascadeDeleteAppointmentImages",
  "changeEmployeeEmail",
  "completeEmployeeSetup",
  "createEmployeeAccount",
  "deleteAccount",
  "deleteClient",
  "deleteEmployeeAccount",
  "findAppointmentConflicts",
  "notifyAppointmentChanges",
  "placesAutocomplete",
  "placesGetDetails",
  "placesReverseGeocode",
  "propagateClientEdits",
  "purgeExpiredHistory",
  "recountAppointmentPictures",
  "recountClientJobs",
  "restoreAppointmentStatus",
  "searchClients",
  "searchHistory",
  "sendDailyJobDigest",
  "sendUpcomingJobReminders",
  "syncClientBuilding",
  "syncUsersByUid",
  "validateUploadedImage",
  "waveBootstrap",
  "waveGetConnection",
  "waveImportCustomers",
  "waveRetryFailedJobs",
  "waveSetImportSchedule",
  "waveUpsertCustomer",
];

describe("index.js export set", () => {
  test("exports exactly the documented function names", () => {
    const index = require("../index");
    expect(Object.keys(index).sort()).toEqual(EXPECTED_EXPORTS);
  });

  test("every export is a deployable function handle", () => {
    // A typo on the right-hand side of `exports.x = mod.y` yields `undefined`,
    // which deploys as a DELETION of that function rather than an error.
    const index = require("../index");
    for (const name of EXPECTED_EXPORTS) {
      expect(typeof index[name]).toBe("function");
    }
  });
});
