/**
 * @fileoverview Hand-mirror suite for `appointment_image_ids.js`.
 *
 * The worked examples here are shared VERBATIM with
 * `test/features/calendar/domain/appointment_image_doc_id_test.dart`. The two
 * implementations must agree exactly: the backfill writes these ids and the
 * client writes them again on every retry of the same photo, so a divergence
 * puts one photo at two ids and it renders twice with nothing erroring.
 * Change a case here, change it there.
 */
const {
  appointmentImageDocId,
  MAX_ID_LENGTH,
} = require("../appointment_image_ids");

// The `img_` prefix the id carries on top of the sanitized key.
const PREFIX_LENGTH = "img_".length;

const REAL_PATH =
  "appointments/aBc123XyZ/images/1754835600000_image_picker_A1.jpg";
const REAL_URL =
  "https://firebasestorage.googleapis.com/v0/b/schedulingapp-88727" +
  ".firebasestorage.app/o/appointments%2FaBc123XyZ%2Fimages%2F" +
  "1754835600000_image_picker_A1.jpg?alt=media&token=" +
  "8f3e1c2a-4b5d-6e7f-8a9b-0c1d2e3f4a5b";

describe("identity", () => {
  test("keys on storagePath, which renders and deletes the photo", () => {
    expect(appointmentImageDocId({storagePath: REAL_PATH, url: REAL_URL}))
        .toBe(
            "img_appointments_aBc123XyZ_images_" +
        "1754835600000_image_picker_A1.jpg");
  });

  test("the same photo always resolves to the same id", () => {
    // The offline queue re-appends an already uploaded photo, so the second
    // write must be a no-op rather than a duplicate. The array form got that
    // from arrayUnion's deep-equality dedupe, which depended on every field
    // serializing identically — a differing uploadedAt broke it.
    expect(appointmentImageDocId({storagePath: REAL_PATH, url: REAL_URL}))
        .toBe(appointmentImageDocId({
          storagePath: REAL_PATH,
          url: REAL_URL,
          fileName: "something_else.jpg",
          uploadedAt: new Date("2020-01-01T00:00:00.000Z"),
        }));
  });

  test("two photos on one appointment do not collide", () => {
    const other =
      "appointments/aBc123XyZ/images/1754835600001_image_picker_A2.jpg";
    expect(appointmentImageDocId({storagePath: REAL_PATH}))
        .not.toBe(appointmentImageDocId({storagePath: other}));
  });
});

describe("the legacy url fallback", () => {
  // Docs predating storagePath carry a url and nothing else — the same ones
  // AppointmentImageUrlResolver falls back for. Without this branch every
  // legacy photo on an appointment keys on "" and they collapse into one.
  test("falls back to url when storagePath is empty", () => {
    const id = appointmentImageDocId({storagePath: "", url: REAL_URL});
    expect(id.startsWith("img_")).toBe(true);
    expect(id).toContain("8f3e1c2a");
  });

  test("two legacy photos with different urls do not collide", () => {
    expect(appointmentImageDocId({url: REAL_URL}))
        .not.toBe(appointmentImageDocId({
          url: REAL_URL.replace("8f3e1c2a", "9a4f2d3b"),
        }));
  });

  test("a whitespace-only storagePath still falls back", () => {
    expect(appointmentImageDocId({storagePath: "   ", url: REAL_URL}))
        .toBe(appointmentImageDocId({storagePath: "", url: REAL_URL}));
  });
});

describe("Firestore id legality", () => {
  test("never contains a slash", () => {
    expect(appointmentImageDocId({storagePath: REAL_PATH})).not.toContain("/");
    expect(appointmentImageDocId({url: REAL_URL})).not.toContain("/");
  });

  test("the img_ prefix keeps the reserved __.*__ shape unreachable", () => {
    // A storage path beginning with "/" sanitizes to a leading underscore,
    // which is how a bare key could reach Firestore's reserved id shape and be
    // rejected at write time.
    const id = appointmentImageDocId({storagePath: "/_x_/"});
    expect(id.startsWith("img_")).toBe(true);
    expect(/^__.*__$/.test(id)).toBe(false);
  });

  test("is never '.' or '..'", () => {
    expect(appointmentImageDocId({storagePath: "."})).toBe("img_.");
    expect(appointmentImageDocId({storagePath: ".."})).toBe("img_..");
  });

  test("caps length while keeping the unique tail", () => {
    // Truncating from the head is what preserves uniqueness — both key shapes
    // carry their distinguishing part at the end.
    const long = `appointments/${"x".repeat(500)}/images/UNIQUE_TAIL.jpg`;
    const id = appointmentImageDocId({storagePath: long});
    expect(id.length).toBeLessThanOrEqual(MAX_ID_LENGTH + PREFIX_LENGTH);
    expect(id.endsWith("UNIQUE_TAIL.jpg")).toBe(true);
  });

  test("two long paths differing only in their tail do not collide", () => {
    const a = `appointments/${"x".repeat(500)}/images/TAIL_A.jpg`;
    const b = `appointments/${"x".repeat(500)}/images/TAIL_B.jpg`;
    expect(appointmentImageDocId({storagePath: a}))
        .not.toBe(appointmentImageDocId({storagePath: b}));
  });
});

test("an image with no identity at all yields an empty id", () => {
  // The caller must skip these rather than write them: Firestore rejects an
  // empty document id, and such an entry has nothing to render anyway.
  expect(appointmentImageDocId({})).toBe("");
  expect(appointmentImageDocId(null)).toBe("");
  expect(appointmentImageDocId({storagePath: "", url: ""})).toBe("");
});
