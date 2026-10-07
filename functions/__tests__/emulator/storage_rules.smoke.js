"use strict";

// Run only through firebase emulators:exec with a demo- project.
const assert = require("node:assert/strict");
const {randomUUID} = require("node:crypto");
const {initializeApp, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {syncUsersByUid} = require("../../bridge");
const {verifySafety} = require("./safety_checks");

/**
 * Runs delayed trigger events against real emulator transactions and Auth.
 * @param {string} project Demo project id.
 * @return {!Promise<void>}
 */
async function verifyBridge(project) {
  const app = initializeApp({projectId: project});
  try {
    const db = getFirestore(app);
    const auth = getAuth(app);
    const user = await auth.createUser({});
    const userId = `bridge-${randomUUID()}`;
    const ref = db.doc(`users/${userId}`);
    const bridge = db.doc(`usersByUid/${user.uid}`);
    const active = {uid: user.uid, status: "active", role: "employee"};
    const disabled = {...active, status: "disabled"};
    const snapshot = (data) => ({exists: data !== null, data: () => data});
    const event = (before, after) => ({
      params: {userId},
      data: {before: snapshot(before), after: snapshot(after)},
    });

    await ref.set(disabled);
    await syncUsersByUid.run(event(null, active));
    assert.equal((await bridge.get()).data().status, "disabled");
    assert.equal((await auth.getUser(user.uid)).disabled, true);

    await ref.delete();
    await syncUsersByUid.run(event(disabled, active));
    assert.equal((await bridge.get()).exists, false);
    assert.equal((await auth.getUser(user.uid)).disabled, true);

    await ref.set(active);
    await syncUsersByUid.run(event(active, disabled));
    assert.equal((await bridge.get()).data().status, "active");
    assert.equal((await auth.getUser(user.uid)).disabled, false);
    console.log("Account trigger: 6 emulator checks passed.");
  } finally {
    await deleteApp(app);
  }
}

/**
 * Exercises Storage authorization using real local rules and Auth tokens.
 * @return {!Promise<void>}
 */
async function main() {
  const project = process.env.GCLOUD_PROJECT;
  assert.match(project || "", /^demo-/);
  const hosts = ["FIRESTORE_EMULATOR_HOST", "FIREBASE_AUTH_EMULATOR_HOST",
    "FIREBASE_STORAGE_EMULATOR_HOST"].map((key) => {
    const host = process.env[key];
    assert.match(host || "", /^(127\.0\.0\.1|localhost):\d+$/);
    return `http://${host}`;
  });
  const [firestore, auth, storage] = hosts;
  const suffix = randomUUID();
  const appointment = `rules-${suffix}`;
  const bucket = `${project}.appspot.com`;
  const object = `appointments/${appointment}/images/evidence.jpg`;
  const jpeg = Buffer.from([0xFF, 0xD8, 0xFF, 0xD9]);

  /**
   * @param {string} path Document path.
   * @param {!Object} fields Firestore REST fields.
   * @return {!Promise<void>}
   */
  async function seed(path, fields) {
    const response = await fetch(`${firestore}/v1/projects/${project}` +
      `/databases/(default)/documents/${path}`, {
      method: "PATCH",
      headers: {
        "Authorization": "Bearer owner", "Content-Type": "application/json",
      },
      body: JSON.stringify({fields}),
    });
    assert.equal(response.status, 200, "emulator seed failed");
    await response.arrayBuffer();
  }

  /**
   * @param {string} role Account role.
   * @param {string} status Account status.
   * @return {!Promise<!Object>} Token and document id.
   */
  async function account(role, status) {
    const response = await fetch(`${auth}/identitytoolkit.googleapis.com/v1/` +
      "accounts:signUp?key=demo-key", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({returnSecureToken: true}),
    });
    assert.equal(response.status, 200, "emulator account creation failed");
    const {idToken, localId} = await response.json();
    const docId = `${role}-${localId}`;
    await seed(`usersByUid/${localId}`, {
      docId: {stringValue: docId},
      role: {stringValue: role},
      status: {stringValue: status},
    });
    return {token: idToken, docId, uid: localId};
  }

  const admin = await account("admin", "active");
  const employee = await account("employee", "active");
  const outsider = await account("employee", "active");
  const disabled = await account("employee", "disabled");
  await seed(`appointments/${appointment}`, {
    employeeIds: {arrayValue: {values: [employee, disabled].map((a) =>
      ({stringValue: a.docId}))}},
  });

  /**
   * @param {string} method HTTP method.
   * @param {?Object} user Account, or null for unauthenticated.
   * @param {string} path Storage object path.
   * @param {string} type MIME type.
   * @return {!Promise<number>} Response status.
   */
  async function request(method, user, path = object, type = "image/jpeg") {
    const encoded = encodeURIComponent(path);
    const url = method === "POST" ?
      `${storage}/v0/b/${bucket}/o?uploadType=media&name=${encoded}` :
      `${storage}/v0/b/${bucket}/o/${encoded}`;
    const response = await fetch(url, {
      method,
      headers: {
        ...(user ? {Authorization: `Firebase ${user.token}`} : {}),
        "Content-Type": method === "PATCH" ? "application/json" : type,
      },
      body: method === "POST" ? jpeg : method === "PATCH" ?
        JSON.stringify({customMetadata: {changed: "true"}}) : undefined,
    });
    await response.arrayBuffer();
    return response.status;
  }

  const denied = (status) => assert.ok([401, 403].includes(status),
      `expected authorization denial, got ${status}`);
  assert.equal(await request("POST", employee), 200, "assignee may add photo");
  denied(await request("POST", employee));
  denied(await request("PATCH", employee));
  denied(await request("DELETE", employee));
  assert.equal(await request("GET", employee), 200, "assignee may read photo");
  denied(await request("POST", outsider, `${object}-outsider`));
  denied(await request("POST", disabled, `${object}-disabled`));
  denied(await request("POST", null, `${object}-anonymous`));
  denied(await request("POST", admin, `${object}-invalid`, "application/pdf"));
  assert.equal(await request("POST", admin), 200, "admin may replace photo");
  assert.equal(await request("PATCH", admin), 200, "admin may edit metadata");
  assert.equal(await request("DELETE", admin), 204, "admin may delete photo");
  console.log("Storage rules: 12 emulator checks passed.");
  await verifyBridge(project);
  await verifySafety(project, firestore, auth, admin);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
