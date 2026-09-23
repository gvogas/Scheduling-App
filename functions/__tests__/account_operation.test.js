"use strict";

jest.mock("firebase-functions/logger", () => ({error: jest.fn()}));
const logger = require("firebase-functions/logger");
const {withAccountOperation} = require("../account_operation");

/** @return {!Object} Atomic create fake and release spy. */
function lockStore() {
  let held = false;
  const ref = {
    create: jest.fn(async () => {
      if (held) throw Object.assign(Error("exists"), {code: 6});
      held = true;
    }),
    delete: jest.fn(async () => {
      held = false;
    }),
  };
  return {ref, db: {collection: () => ({doc: () => ref})}};
}

test("another writer is refused until the entire first operation finishes",
    async () => {
      const {db, ref} = lockStore();
      let release;
      let started;
      const entered = new Promise((resolve) => {
        started = resolve;
      });
      const pending = withAccountOperation(db, "uid", "setup", async () => {
        started();
        return new Promise((resolve) => {
          release = resolve;
        });
      });
      await entered;
      const work = jest.fn();
      await expect(withAccountOperation(db, "uid", "reset", work))
          .rejects.toThrow("account-operation-in-progress");
      expect(work).not.toHaveBeenCalled();
      expect(ref.delete).not.toHaveBeenCalled();
      release("done");
      await expect(pending).resolves.toBe("done");
      await withAccountOperation(db, "uid", "reset", work);
      expect(work).toHaveBeenCalledTimes(1);
    });

test("failed work releases its lock and preserves the error", async () => {
  const {db, ref} = lockStore();
  await expect(withAccountOperation(db, "uid", "setup", async () => {
    throw Error("failure");
  })).rejects.toThrow("failure");
  expect(ref.delete).toHaveBeenCalledTimes(1);
});

test("release failure is reported without rolling back successful work",
    async () => {
      const {db, ref} = lockStore();
      ref.delete.mockRejectedValue(Error("offline"));
      await expect(withAccountOperation(db, "uid", "setup", async () => "ok"))
          .resolves.toBe("ok");
      expect(logger.error).toHaveBeenCalledWith(
          "Account operation lock needs recovery",
          {uid: "uid", operation: "setup"});
      await expect(withAccountOperation(db, "uid", "setup", jest.fn()))
          .rejects.toThrow("account-operation-in-progress");
    });

test("unexpected acquire failure never runs work or removes a lock",
    async () => {
      const {db, ref} = lockStore();
      ref.create.mockRejectedValue(Error("offline"));
      const work = jest.fn();
      await expect(withAccountOperation(db, "uid", "setup", work))
          .rejects.toThrow("offline");
      expect(work).not.toHaveBeenCalled();
      expect(ref.delete).not.toHaveBeenCalled();
    });
