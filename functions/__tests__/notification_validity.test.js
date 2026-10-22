"use strict";

const {notificationValidUntil} = require("../notification_validity");

test.each([
  ["leaveNow", 15], ["reminder", 30], ["doneCheck", 120],
  ["digest", 720], ["overdueReview", 1440], ["assigned", 1440],
])("%s expires after %i minutes", (kind, minutes) => {
  expect(notificationValidUntil(kind, 1000)).toBe(1000 + minutes * 60000);
});

test("a job cutoff wins over a later retry budget", () => {
  expect(notificationValidUntil("reminder", 1000, 2000)).toBe(2000);
  expect(notificationValidUntil("reminder", 1000, 500)).toBe(500);
});
