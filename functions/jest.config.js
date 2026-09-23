"use strict";

/**
 * @fileoverview Jest configuration for the Cloud Functions suite.
 * There was none, so nothing enforced the coverage the suite already has:
 * no `coverageThreshold`, no `collectCoverageFrom`, and coverage could
 * therefore regress silently — a deleted test or a new untested branch just
 * lowers a number nobody reads. The thresholds below are a RATCHET set a
 * couple of points under the measured baseline (83.32 stmts / 77.44 branch /
 * 85.64 fn / 84.06 line on 2026-09-01), not a target: the slack absorbs
 * ordinary movement, and a real drop still fails.
 * Raise them when the real number rises. Never lower one to make a build
 * pass — that is the regression the file exists to catch.
 */
module.exports = {
  testEnvironment: "node",
  testPathIgnorePatterns: [
    "/node_modules/", "/__tests__/mocks/", "/__tests__/emulator/",
  ],
  moduleNameMapper: {
    "^jose$": "<rootDir>/__tests__/mocks/jose.js",
  },
  // `scripts/` is included on purpose: its backfills and counters produce the
  // migration numbers this project makes decisions on, and un-ignoring that
  // directory for the linter is what exposed a backfill whose `--dry-run` wrote
  // everything and then threw.
  collectCoverageFrom: [
    "**/*.js",
    "!**/node_modules/**",
    "!**/__tests__/**",
    "!coverage/**",
    "!jest.config.js",
    "!.eslintrc.js",
  ],
  coverageThreshold: {
    global: {
      statements: 81,
      branches: 75,
      functions: 83,
      lines: 82,
    },
  },
};
