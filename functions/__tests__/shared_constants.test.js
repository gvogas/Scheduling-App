"use strict";

const constants = require("../../test/fixtures/shared/constants.json");
const {TOKEN_QUERY_LIMIT, TOKEN_FIELD_LIMIT} = require("../search_tokens");
const {MAX_APPOINTMENT_SPAN_DAYS} = require("../day_slice_utils");
const {MAX_ID_LENGTH} = require("../appointment_image_ids");

describe("constants shared with the Dart side", () => {
  test("search token limits", () => {
    expect(TOKEN_QUERY_LIMIT).toBe(constants.searchTokenQueryLimit);
    expect(TOKEN_FIELD_LIMIT).toBe(constants.searchTokenFieldLimit);
  });

  test("the multi-day span cap", () => {
    expect(MAX_APPOINTMENT_SPAN_DAYS).toBe(constants.maxAppointmentSpanDays);
  });

  test("the appointment image id cap", () => {
    expect(MAX_ID_LENGTH).toBe(constants.appointmentImageIdMaxLength);
  });
});
