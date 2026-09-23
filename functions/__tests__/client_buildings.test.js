"use strict";

jest.mock("firebase-admin/firestore", () => ({getFirestore: jest.fn()}));
const {getFirestore} = require("firebase-admin/firestore");
const {
  buildingFor, filterPatchFor, reconcileClientBuilding, syncClientBuilding,
} = require("../client_buildings");
const {backfillBuildings} = require("../scripts/backfill-client-buildings");
const cases = require("../../test/fixtures/client_building_cases.json");

/**
 * Transaction store with atomic staged writes and a read-before-write check.
 * @return {!Object} Store and Firestore facade.
 */
function store() {
  const rows = new Map();
  const snapshot = (ref) => ({
    ref, id: ref.id, exists: rows.has(ref.path), data: () => rows.get(ref.path),
  });
  const db = {
    collection: (collection) => ({
      doc: (id) => ({id, path: `${collection}/${id}`}),
      orderBy: () => ({limit: () => ({get: async () => {
        const docs = [...rows.keys()].filter((p) =>
          p.startsWith(`${collection}/`)).map((path) =>
          snapshot({path, id: path.split("/")[1]}));
        return {docs, size: docs.length, empty: docs.length === 0};
      }})}),
    }),
    runTransaction: async (work) => {
      const writes = [];
      const result = await work({
        get: async (ref) => {
          expect(writes).toHaveLength(0);
          return snapshot(ref);
        },
        set: (ref, data) => writes.push(() => rows.set(ref.path, data)),
        update: (ref, data) => writes.push(() =>
          rows.set(ref.path, {...rows.get(ref.path), ...data})),
        delete: (ref) => writes.push(() => rows.delete(ref.path)),
      });
      writes.forEach((write) => write());
      return result;
    },
  };
  const summaries = () => [...rows.entries()]
      .filter(([key]) => key.startsWith("clientBuildings/")).map(([, v]) => v);
  return {db, rows, summaries};
}

test.each(cases)("building identity: $description", ({data, key}) => {
  expect(buildingFor(data)?.key || null).toBe(key);
});

test("retries do not inflate counts; moves/archive/deletes reconcile live data",
    async () => {
      const {db, rows, summaries} = store();
      rows.set("clients/a", {address: "1-123 Main", city: "Laval"});
      rows.set("clients/b", {address: "2-123 Main", city: "Laval"});
      await reconcileClientBuilding(db, "a");
      await reconcileClientBuilding(db, "b");
      await reconcileClientBuilding(db, "a");
      expect(summaries()[0].clientCount).toBe(2);
      rows.set("clients/a", {address: "300 Other", city: "Laval"});
      await reconcileClientBuilding(db, "a");
      expect(summaries().map((b) => b.clientCount)).toEqual([1, 1]);
      rows.set("clients/a", {...rows.get("clients/a"), archived: true});
      await reconcileClientBuilding(db, "a");
      expect(summaries()).toHaveLength(1);
      rows.delete("clients/b");
      await reconcileClientBuilding(db, "b");
      await reconcileClientBuilding(db, "b");
      expect(summaries()).toHaveLength(0);
      expect(rows.has("clientBuildingMemberships/b")).toBe(false);
    });

test("missing address has an empty indexed key and no membership", async () => {
  const {db, rows, summaries} = store();
  rows.set("clients/a", {});
  await reconcileClientBuilding(db, "a");
  expect(rows.get("clients/a").buildingKey).toBe("");
  expect(summaries()).toEqual([]);
});

test("backfill dry-run writes nothing; applying twice preserves counts",
    async () => {
      const {db, rows, summaries} = store();
      rows.set("clients/a", {address: "123 Main"});
      expect(await backfillBuildings(db, true)).toEqual({
        scanned: 1, projectionsChanged: 1, dryRun: true,
      });
      expect(rows.size).toBe(1);
      await backfillBuildings(db, false);
      await backfillBuildings(db, false);
      expect(summaries()[0].clientCount).toBe(1);
    });

test("canonical filters preserve existing parser behavior for legacy fields",
    () => {
      expect(filterPatchFor({address: "123 Main", type: " commercial "}))
          .toEqual({buildingKey: "123 main|", archived: false, type: "commercial"});
      expect(filterPatchFor({buildingKey: "", archived: true, type: "unknown"}))
          .toEqual({});
    });

test("irrelevant edits and projection echoes do no Firestore work", async () => {
  getFirestore.mockClear();
  const data = {address: "123 Main", archived: false, buildingKey: "123 main|"};
  const snap = (fields) => ({exists: true, data: () => fields});
  await syncClientBuilding.run({
    params: {clientId: "a"}, data: {
      before: snap({...data, buildingKey: undefined}),
      after: snap({...data, jobCount: 8}),
    },
  });
  expect(getFirestore).not.toHaveBeenCalled();
});

test("a delayed deletion event reconciles a recreated client's live address",
    async () => {
      const {db, rows, summaries} = store();
      rows.set("clients/a", {address: "456 New"});
      getFirestore.mockReturnValue(db);
      await syncClientBuilding.run({
        params: {clientId: "a"}, data: {
          before: {exists: true, data: () => ({address: "123 Old"})},
          after: {exists: false},
        },
      });
      expect(summaries()[0].key).toBe("456 new|");
      expect(summaries()[0].clientCount).toBe(1);
    });
