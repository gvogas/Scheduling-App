"use strict";

const assert = require("node:assert/strict");
const {randomUUID} = require("node:crypto");
const {initializeApp, deleteApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {performDeleteClient} = require("../../clients");
const {withAccountOperation} = require("../../account_operation");
const {createEmployeeAccount, completeEmployeeSetup} =
  require("../../employee_accounts");
const {reconcileClientBuilding} = require("../../client_buildings");
const {backfillBuildings} = require("../../scripts/backfill-client-buildings");

/**
 * Invoked only after the parent smoke runner has validated demo/local hosts.
 * @param {string} project Demo project.
 * @param {string} firestore REST origin.
 * @param {string} auth REST origin.
 * @param {!Object} admin Emulator credential.
 * @return {!Promise<void>}
 */
async function verifySafety(project, firestore, auth, admin) {
  const app = initializeApp({projectId: project});
  try {
    const db = getFirestore(app);
    const prefix = randomUUID();
    const client = db.collection("clients").doc(`${prefix}-client`);
    const write = async (path, fields, mask = "") => {
      const response = await fetch(`${firestore}/v1/projects/${project}` +
        `/databases/(default)/documents/${path}${mask}`, {
        method: "PATCH",
        headers: {
          "Authorization": `Bearer ${admin.token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({fields}),
      });
      await response.arrayBuffer();
      return response.status;
    };
    const book = (id, clientId) => write(`appointments/${id}`, {
      status: {stringValue: "pending"},
      clientId: {stringValue: clientId},
    });
    await client.set({name: "Test", archived: false});
    let reached;
    let release;
    const counting = new Promise((resolve) => {
      reached = resolve;
    });
    const held = new Promise((resolve) => {
      release = resolve;
    });
    const pausedDb = {
      runTransaction: (...args) => db.runTransaction(...args),
      collection: (name) => name !== "appointments" ? db.collection(name) : {
        where: (...args) => ({count: () => ({get: async () => {
          reached();
          await held;
          return db.collection(name).where(...args).count().get();
        }})}),
      },
    };
    const deletion = performDeleteClient(pausedDb, client.id);
    await counting;
    assert.equal(await book(`${prefix}-during`, client.id), 403);
    release();
    await deletion;
    assert.equal((await client.get()).exists, false);
    assert.equal(await book(`${prefix}-after`, client.id), 403);
    assert.equal(await book(`${prefix}-personal`, ""), 200);

    await client.set({name: "Test", archived: false});
    assert.equal(await book(`${prefix}-before`, client.id), 200);
    await assert.rejects(performDeleteClient(db, client.id),
        /client-has-history/);
    assert.equal((await client.get()).data().deletionToken, "");
    assert.equal(await book(`${prefix}-before`, "nonexistent-client"), 403);
    assert.equal(await write(`clients/${client.id}`, {
      deletionToken: {stringValue: "forged"},
    }, "?updateMask.fieldPaths=deletionToken"), 403);
    for (let index = 0; index < 8; index++) {
      const raced = db.collection("clients").doc(`${prefix}-race-${index}`);
      await raced.set({name: "Race", archived: false});
      const booking = book(`${prefix}-race-job-${index}`, raced.id);
      const removal = performDeleteClient(db, raced.id);
      const [booked] = await Promise.allSettled([booking, removal]);
      assert.equal(booked.status, "fulfilled");
      assert.ok([200, 403].includes(booked.value));
      if (booked.value === 200) {
        assert.equal((await raced.get()).exists, true,
            "a committed booking must retain its client");
      }
    }
    console.log("Client deletion: both booking commit orders checked.");

    const email = `${prefix}@example.test`;
    const fields = {name: "Test Employee", email, colorValue: "1"};
    const created = await createEmployeeAccount.run({
      auth: {uid: admin.uid}, data: fields,
    });
    const person = (await db.collection("users")
        .where("email", "==", email).get()).docs[0];
    const uid = person.data().uid;
    assert.equal(await write(`users/${person.id}`, {
      setupRequiresPassword: {booleanValue: false},
    }, "?updateMask.fieldPaths=setupRequiresPassword"), 403);
    const setup = {
      auth: {uid},
      data: {newPassword: "ChosenPassword123!", termsAccepted: true},
    };
    await withAccountOperation(db, uid, "test-held-operation", async () => {
      await assert.rejects(completeEmployeeSetup.run(setup),
          /operation-in-progress/);
      await assert.rejects(createEmployeeAccount.run({
        auth: {uid: admin.uid}, data: fields,
      }), /operation-in-progress/);
    });
    // Reissue a starting password, then exercise the legacy setup request.
    await createEmployeeAccount.run({auth: {uid: admin.uid}, data: fields});
    await assert.rejects(completeEmployeeSetup.run({
      auth: {uid}, data: {termsAccepted: true},
    }), /setup-upgrade-required/);
    assert.equal((await person.ref.get()).data().status, "invited");
    await completeEmployeeSetup.run(setup);
    assert.equal((await person.ref.get()).data().status, "active");
    await assert.rejects(createEmployeeAccount.run({
      auth: {uid: admin.uid}, data: fields,
    }), /email-exists/);
    const signIn = await fetch(`${auth}/identitytoolkit.googleapis.com/v1/` +
      "accounts:signInWithPassword?key=demo-key", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({email, password: setup.data.newPassword}),
    });
    assert.equal(signIn.status, 200);
    await signIn.arrayBuffer();
    assert.notEqual(created.password, setup.data.newPassword);
    const releasedLock = await db.collection("accountOperations")
        .doc(uid).get();
    assert.equal(releasedLock.exists, false);
    console.log("Account setup: contention and chosen credential checked.");

    const first = db.collection("clients").doc(`${prefix}-building-1`);
    const second = db.collection("clients").doc(`${prefix}-building-2`);
    await first.set({address: "101-123 Rue Test", city: "Montréal"});
    await second.set({address: "202-123 Rue Test", city: "Montreal"});
    const preview = await backfillBuildings(db, true);
    assert.ok(preview.projectionsChanged >= 2);
    assert.equal((await first.get()).data().buildingKey, undefined);
    await Promise.all([
      reconcileClientBuilding(db, first.id),
      reconcileClientBuilding(db, second.id),
    ]);
    await reconcileClientBuilding(db, first.id); // duplicate delivery
    const key = (await first.get()).data().buildingKey;
    const summaries = await db.collection("clientBuildings")
        .where("key", "==", key).get();
    assert.equal(summaries.size, 1);
    assert.equal(summaries.docs[0].data().clientCount, 2);
    await second.update({archived: true});
    await reconcileClientBuilding(db, second.id); // latest state, stale event
    assert.equal((await summaries.docs[0].ref.get()).data().clientCount, 1);
    await first.delete();
    await reconcileClientBuilding(db, first.id);
    assert.equal((await summaries.docs[0].ref.get()).exists, false);
    console.log("Building catalog: concurrency/retry/archive/delete checked.");
  } finally {
    await deleteApp(app);
  }
}

module.exports = {verifySafety};
