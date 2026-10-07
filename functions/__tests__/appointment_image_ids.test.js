/**
 * @fileoverview Exact-id examples are shared with the Dart suite through
 * test/fixtures/shared/image_ids.json; only JS-specific shapes live here.
 */
const {appointmentImageDocId, MAX_ID_LENGTH} =
  require("../appointment_image_ids");
const {cases} = require("../../test/fixtures/shared/image_ids.json");

describe("shared examples", () => {
  test.each(cases)("$name", (c) => {
    expect(appointmentImageDocId({storagePath: c.storagePath, url: c.url}))
        .toBe(c.expect);
  });
});

test("fields other than storagePath and url do not change the id", () => {
  const storagePath =
    "appointments/aBc123XyZ/images/1754835600000_image_picker_A1.jpg";
  expect(appointmentImageDocId({storagePath})).toBe(appointmentImageDocId({
    storagePath,
    fileName: "something_else.jpg",
    uploadedAt: new Date("2020-01-01T00:00:00.000Z"),
  }));
});

test("a missing or null image yields an empty id", () => {
  expect(appointmentImageDocId({})).toBe("");
  expect(appointmentImageDocId(null)).toBe("");
});

test("caps length while keeping the unique tail", () => {
  const long = `appointments/${"x".repeat(500)}/images/UNIQUE_TAIL.jpg`;
  const id = appointmentImageDocId({storagePath: long});
  expect(id.length).toBe("img_".length + MAX_ID_LENGTH);
  expect(id.endsWith("UNIQUE_TAIL.jpg")).toBe(true);
});

test("two long paths differing only in their tail do not collide", () => {
  const a = `appointments/${"x".repeat(500)}/images/TAIL_A.jpg`;
  const b = `appointments/${"x".repeat(500)}/images/TAIL_B.jpg`;
  expect(appointmentImageDocId({storagePath: a}))
      .not.toBe(appointmentImageDocId({storagePath: b}));
});
