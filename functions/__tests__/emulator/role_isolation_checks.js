"use strict";

const assert = require("node:assert/strict");
const {randomUUID} = require("node:crypto");
const {initializeApp, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");

/**
 * Cross-role read and write isolation against the real firestore.rules.
 * Invoked only after the parent smoke runner has validated demo/local hosts.
 * @param {string} project Demo project.
 * @param {string} firestore REST origin.
 * @param {!Object} admin Active admin credential.
 * @param {!Object} employee Active employee assigned to the seeded job.
 * @param {!Object} outsider Active employee on no job.
 * @param {!Object} disabled Disabled employee assigned to the seeded job.
 * @return {!Promise<void>}
 */
async function verifyRoleIsolation(project, firestore, admin, employee,
    outsider, disabled) {
  const app = initializeApp({projectId: project}, `isolation-${randomUUID()}`);
  try {
    const db = getFirestore(app);
    const prefix = `iso-${randomUUID()}`;
    const job = `appointments/${prefix}-job`;
    const people = {employee, outsider, disabled};
    for (const [label, person] of Object.entries(people)) {
      await db.doc(`users/${person.docId}`).set({
        uid: person.uid,
        name: label,
        role: "employee",
        status: label === "disabled" ? "disabled" : "active",
      });
      await db.doc(`users/${person.docId}/private/emergency`)
          .set({contact: `${label} contact`, phone: "555"});
      await db.doc(`users/${person.docId}/presence/location`)
          .set({lat: 45, lng: -73, uid: person.uid});
    }
    await db.doc(job).set({
      status: "pending",
      title: "Isolation",
      employeeIds: [employee.docId, disabled.docId],
    });
    await db.doc(`clients/${prefix}-client`).set({name: "Client 555"});

    const base = `${firestore}/v1/projects/${project}/databases/(default)` +
      "/documents";
    /**
     * @param {string} method HTTP verb.
     * @param {?Object} user Credential, or null for unauthenticated.
     * @param {string} path Document path, or ":runQuery".
     * @param {?Object} body JSON body.
     * @return {!Promise<number>} Response status.
     */
    const call = async (method, user, path, body = null) => {
      const url = path.startsWith(":") ? `${base}${path}` : `${base}/${path}`;
      const response = await fetch(url, {
        method,
        headers: {
          ...(user ? {Authorization: `Bearer ${user.token}`} : {}),
          "Content-Type": "application/json",
        },
        body: body ? JSON.stringify(body) : undefined,
      });
      await response.arrayBuffer();
      return response.status;
    };
    const read = (user, path) => call("GET", user, path);
    const patch = (user, path, fields) => call("PATCH", user,
        `${path}?${Object.keys(fields)
            .map((f) => `updateMask.fieldPaths=${f}`).join("&")}`,
        {fields});
    const listAll = (user, collection) => call("POST", user, ":runQuery",
        {structuredQuery: {from: [{collectionId: collection}], limit: 5}});
    const denied = (status, what) =>
      assert.ok([401, 403].includes(status), `${what}: got ${status}`);

    assert.equal(await read(employee, job), 200, "assignee reads own job");
    denied(await read(outsider, job), "outsider reads unassigned job");
    denied(await read(disabled, job), "disabled assignee reads job");
    denied(await read(null, job), "anonymous reads job");
    denied(await listAll(employee, "appointments"),
        "employee lists every appointment");
    denied(await read(employee, `clients/${prefix}-client`),
        "employee reads client PII");
    denied(await listAll(employee, "clients"), "employee lists clients");

    const own = `users/${employee.docId}`;
    denied(await patch(employee, own, {role: {stringValue: "admin"}}),
        "employee promotes self");
    denied(await patch(disabled, `users/${disabled.docId}`,
        {status: {stringValue: "active"}}), "disabled user reactivates self");
    denied(await patch(employee, `users/${outsider.docId}`,
        {phone: {stringValue: "1"}}), "employee edits a peer");
    denied(await read(employee, `users/${outsider.docId}/private/emergency`),
        "employee reads a peer's emergency contact");
    assert.equal(await read(employee, `${own}/private/emergency`), 200,
        "employee reads own emergency contact");
    denied(await read(employee, `users/${outsider.docId}/presence/location`),
        "employee reads a peer's location");
    denied(await listAll(null, "users"), "anonymous lists staff");

    for (const ledger of ["rateLimits", "wave", "waveSyncQueue",
      "appointmentReminders", "liveActivityCards"]) {
      denied(await patch(admin, `${ledger}/${prefix}`,
          {x: {stringValue: "1"}}), `admin writes ${ledger}`);
    }
    denied(await patch(employee, `usersByUid/${employee.uid}`,
        {role: {stringValue: "admin"}}), "employee rewrites own bridge row");
    denied(await patch(employee,
        `users/${outsider.docId}/fcmTokens/${prefix}`, {
          platform: {stringValue: "ios"},
          locale: {stringValue: "en"},
          uid: {stringValue: employee.uid},
        }), "employee plants a token under a peer");
    console.log("Role isolation: 21 emulator checks passed.");
  } finally {
    await deleteApp(app);
  }
}

module.exports = {verifyRoleIsolation};
