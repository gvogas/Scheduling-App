"use strict";

const {resolveEmailChangeCaller} = require("../employee_accounts_self");

describe("resolveEmailChangeCaller", () => {
  const admin = {role: "admin", status: "active", docId: "adm"};
  const employee = {role: "employee", status: "active", docId: "u1"};

  test("an active admin may change any doc", async () => {
    await expect(resolveEmailChangeCaller(admin, "u1"))
        .resolves.toEqual({isSelf: false, isAdmin: true, callerDocId: "adm"});
  });

  test("an active employee may change their OWN doc", async () => {
    await expect(resolveEmailChangeCaller(employee, "u1"))
        .resolves.toEqual({isSelf: true, isAdmin: false, callerDocId: "u1"});
  });

  test("an admin changing their own doc is still the admin path", async () => {
    // isSelf drives who gets NOTIFIED, so it must reflect who actually acted.
    // An admin editing their own row told nobody under an isSelf:false read.
    //
    // isAdmin stays TRUE here, and the two must not be collapsed: the re-auth
    // freshness gate keys on isAdmin, and every admin call — this one included
    // — arrives through `updateEmployee`, which has no re-auth step to satisfy
    // it. Keying that gate on isSelf rejected an admin's own-row save outright.
    await expect(resolveEmailChangeCaller(admin, "adm"))
        .resolves.toEqual({isSelf: true, isAdmin: true, callerDocId: "adm"});
  });

  test("an employee may NOT change someone else's doc", async () => {
    // The whole point of the branch: widening this callable past admins must
    // not widen WHICH doc a caller can reach.
    await expect(resolveEmailChangeCaller(employee, "u2"))
        .rejects.toThrow("not-admin");
  });

  test("a DISABLED employee may not change their own doc", async () => {
    await expect(resolveEmailChangeCaller(
        {role: "employee", status: "disabled", docId: "u1"}, "u1",
    )).rejects.toThrow("not-admin");
  });

  test("an INVITED employee may not change their own doc", async () => {
    // Mid-setup: completeEmployeeSetup owns that doc, and the person is still
    // on the shared starting password.
    await expect(resolveEmailChangeCaller(
        {role: "employee", status: "invited", docId: "u1"}, "u1",
    )).rejects.toThrow("not-admin");
  });

  test("a DISABLED admin may not change anything", async () => {
    await expect(resolveEmailChangeCaller(
        {role: "admin", status: "disabled", docId: "adm"}, "u1",
    )).rejects.toThrow("not-admin");
  });

  test("a missing bridge doc is refused", async () => {
    // Fails CLOSED on absent input, rather than reading undefined as a pass.
    await expect(resolveEmailChangeCaller(null, "u1"))
        .rejects.toThrow("not-admin");
  });

  test("a bridge doc with no docId cannot match any target", async () => {
    // An empty docId must not accidentally equal an empty target id.
    await expect(resolveEmailChangeCaller(
        {role: "employee", status: "active"}, "",
    )).rejects.toThrow("not-admin");
  });

  test("an unknown role is refused", async () => {
    await expect(resolveEmailChangeCaller(
        {role: "contractor", status: "active", docId: "u9"}, "u1",
    )).rejects.toThrow("not-admin");
  });
});
