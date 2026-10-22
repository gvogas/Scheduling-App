"use strict";

/**
 * @fileoverview GraphQL transport client for the Wave Accounting public API.
 *
 * All network I/O is funnelled through `graphql()`, with every argument value
 * passed via `variables` rather than string-interpolated into the query
 * document. Wave rejects inline String-typed args anyway, and this keeps
 * calls injection-safe as a bonus.
 *
 * Retry policy (exponential backoff + jitter):
 *   - 429 Too Many Requests: respect `Retry-After` header when present.
 *   - 5xx / fetch rejection (network): retry with backoff.
 *   - 401 / 403: throw immediately — no retry (token missing or revoked).
 *   - Any other non-2xx: throw immediately.
 *
 * All retry parameters and I/O dependencies are injectable via the `options`
 * bag so unit tests can run instantly without real network or secrets.
 *
 * @module wave/client
 */

const WAVE_GQL_URL = "https://gql.waveapps.com/graphql/public";

// Default retry settings, overridable via options.maxRetries / sleepFn.
const DEFAULT_MAX_RETRIES = 3;
const BASE_DELAY_MS = 500;
const MAX_DELAY_MS = 10_000;
// We clamp the Retry-After header to this so a rogue or misconfigured
// server can't stall the function past its Cloud Run timeout.
const MAX_RETRY_AFTER_MS = 60_000;
const DEFAULT_REQUEST_TIMEOUT_MS = 20_000;

// ---------------------------------------------------------------------------
// WaveApiError
// ---------------------------------------------------------------------------

/**
 * Structured error thrown by all Wave client functions.
 *
 * `kind` values:
 *   - `'auth'`        — 401/403; token missing or revoked.
 *   - `'rateLimited'` — 429 persisting after all retries.
 *   - `'network'`     — 5xx or fetch rejection persisting after all retries.
 *   - `'graphql'`     — HTTP 200 but the body carries a top-level `errors`
 *                       array (GraphQL transport / resolver errors).
 *   - `'unknown'`     — Unexpected HTTP status with no matching category.
 */
class WaveApiError extends Error {
  /**
   * @param {string} kind Error category (see jsdoc above).
   * @param {string} message Human-readable description.
   * @param {*=} details Optional raw details (error array, status code, etc.).
   */
  constructor(kind, message, details) {
    super(message);
    this.name = "WaveApiError";
    /** @type {string} */
    this.kind = kind;
    /** @type {*} */
    this.details = details;
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * Delay in milliseconds for retry attempt `n` (0-indexed): min(BASE * 2^n,
 * MAX) * (0.5 + random 0..0.5) for jitter.
 * @param {number} n Attempt index (0 = first retry).
 * @return {number} Delay in milliseconds.
 */
function backoffMs(n) {
  const exp = Math.min(BASE_DELAY_MS * Math.pow(2, n), MAX_DELAY_MS);
  return Math.floor(exp * (0.5 + Math.random() * 0.5));
}

/**
 * Parses the `Retry-After` header (integer-seconds or HTTP-date form) into a
 * millisecond delay, or `null` when absent/unparseable.
 * @param {Headers} headers Response headers.
 * @return {number|null}
 */
function retryAfterMs(headers) {
  const raw = headers.get("retry-after");
  if (!raw) return null;
  const secs = Number(raw.trim());
  if (!isNaN(secs) && secs >= 0) return secs * 1000;
  const date = Date.parse(raw);
  if (!isNaN(date)) return Math.max(0, date - Date.now());
  return null;
}

/**
 * Drains a response body so its socket isn't pinned across the retry loop —
 * Undici/Node fetch requires this. We swallow any errors here since this is
 * just a resource release, not something worth failing over.
 * @param {*} response A fetch Response (or a test double without `.text`).
 * @return {!Promise<void>}
 */
async function discardBody(response) {
  try {
    if (response && typeof response.text === "function") {
      await response.text();
    }
  } catch {
    // Best-effort drain — the caller is already on an error path anyway.
  }
}

// ---------------------------------------------------------------------------
// Core transport
// ---------------------------------------------------------------------------

/**
 * Runs the POST-with-retry loop and returns the first 2xx response.
 *
 * 429 (honoring a clamped `Retry-After`), 5xx, and fetch rejections all get
 * retried up to `maxRetries` times. 401/403 and any other non-2xx throw
 * right away. Every path drains the body first so sockets aren't pinned
 * across the loop.
 *
 * @param {string} requestBody Serialized GraphQL request body.
 * @param {!Object} requestHeaders Request headers including Authorization.
 * @param {!Function} fetchImpl Fetch implementation.
 * @param {number} maxRetries Maximum retries after the first attempt.
 * @param {!Object} budget Signal and remaining deadline function.
 * @return {!Promise<*>} The 2xx fetch Response.
 * @throws {WaveApiError}
 */
async function postWithRetry(
    requestBody, requestHeaders, fetchImpl, maxRetries, budget) {
  let attempt = 0;
  // `attempt` counts total tries. We allow up to maxRetries retries after
  // the first attempt, so the loop runs at most maxRetries + 1 times.
  for (;;) {
    let response;
    let fetchError = null;

    try {
      if (budget.remaining() <= 0 || budget.signal.aborted) {
        throw new WaveApiError("network", "Wave request deadline exceeded.");
      }
      response = await fetchImpl(WAVE_GQL_URL, {
        method: "POST",
        headers: requestHeaders,
        body: requestBody,
        signal: budget.signal,
      });
    } catch (err) {
      fetchError = err;
    }

    // Network / fetch rejection → retry or throw.
    if (fetchError !== null) {
      if (attempt < maxRetries) {
        await budget.sleep(backoffMs(attempt), "network");
        attempt++;
        continue;
      }
      throw new WaveApiError(
          "network",
          `Wave fetch failed after ${attempt + 1} attempt(s): ` +
          fetchError.message,
          fetchError,
      );
    }

    const status = response.status;

    // Auth errors: no retry.
    if (status === 401 || status === 403) {
      await discardBody(response);
      throw new WaveApiError(
          "auth",
          `Wave API returned ${status} — token missing or revoked.`,
          status,
      );
    }

    // Rate limit: retry with Retry-After or backoff.
    if (status === 429) {
      await discardBody(response);
      if (attempt < maxRetries) {
        const headerDelay = retryAfterMs(response.headers);
        // A header value of 0 is valid and should be honored — we only fall
        // back to backoff when the header is genuinely absent (null). We
        // also clamp to MAX_RETRY_AFTER_MS so a huge header can't stall us.
        const delay = headerDelay == null ?
          backoffMs(attempt) :
          Math.min(headerDelay, MAX_RETRY_AFTER_MS);
        await budget.sleep(delay, "rateLimited");
        attempt++;
        continue;
      }
      throw new WaveApiError(
          "rateLimited",
          `Wave API rate-limited after ${attempt + 1} attempt(s).`,
          status,
      );
    }

    // Server errors: retry or throw.
    if (status >= 500 && status <= 599) {
      await discardBody(response);
      if (attempt < maxRetries) {
        await budget.sleep(backoffMs(attempt), "network");
        attempt++;
        continue;
      }
      throw new WaveApiError(
          "network",
          `Wave API returned ${status} after ${attempt + 1} attempt(s).`,
          status,
      );
    }

    // Unexpected non-2xx.
    if (status < 200 || status > 299) {
      await discardBody(response);
      throw new WaveApiError(
          "unknown",
          `Wave API returned unexpected status ${status}.`,
          status,
      );
    }

    return response;
  }
}

/**
 * Parses a 2xx Wave response body into its `data` field. Throws `network`
 * for a non-JSON body, `unknown` for a null/array/non-object body, and
 * `graphql` when the body carries a non-empty top-level `errors` array —
 * that's how Wave reports resolver failures even on an HTTP 200.
 *
 * @param {*} response A 2xx fetch Response.
 * @return {!Promise<*>} The `data` field of the GraphQL response.
 * @throws {WaveApiError}
 */
async function parseGraphqlResponse(response) {
  let body;
  try {
    body = await response.json();
  } catch (err) {
    throw new WaveApiError(
        "network",
        `Wave API returned non-JSON 2xx response: ${err.message}`,
        err,
    );
  }

  // Guard against null or non-object bodies (e.g. null, array) before we
  // touch any properties, so we don't throw a raw TypeError.
  if (body === null || Array.isArray(body) || typeof body !== "object") {
    throw new WaveApiError(
        "unknown",
        "Wave API returned a 2xx response with an unexpected body shape.",
        body,
    );
  }

  if (Array.isArray(body.errors) && body.errors.length > 0) {
    const messages = body.errors
        .map((e) => (typeof e.message === "string" ? e.message : String(e)))
        .join("; ");
    throw new WaveApiError(
        "graphql",
        `Wave GraphQL errors: ${messages}`,
        body.errors,
    );
  }

  return body.data;
}

/**
 * Posts a GraphQL request to the Wave public API and returns `body.data`.
 *
 * @param {string} query GraphQL query or mutation document string.
 * @param {!Object=} variables GraphQL variables (all argument values go here
 *   — never string-interpolate values into `query`).
 * @param {Object=} options Dependency-injection bag (token, fetchImpl,
 *   sleepFn, maxRetries), defaulting to getWaveToken(), global.fetch, a
 *   setTimeout-based delay, and 3 retries respectively.
 * @return {!Promise<*>} The `data` field of a successful GraphQL response.
 * @throws {WaveApiError}
 */
async function graphql(query, variables = {}, options = {}) {
  const {getWaveToken} = require("./auth");
  const token = options.token !== undefined ? options.token : getWaveToken();
  const fetchImpl = options.fetchImpl || global.fetch;
  const maxRetries = options.maxRetries !== undefined ?
    options.maxRetries : DEFAULT_MAX_RETRIES;
  const sleepFn = options.sleepFn || ((ms) =>
    new Promise((resolve) => setTimeout(resolve, ms)));
  const clock = options.wallClock || Date.now;
  const timeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
  const deadline = Math.min(clock() + timeoutMs,
      options.deadlineMs ?? Infinity);
  const remaining = () => deadline - clock();
  if (remaining() <= 0) {
    throw new WaveApiError("network", "Wave request deadline exceeded.");
  }
  const controller = new AbortController();
  const budget = {signal: controller.signal, remaining,
    sleep: async (ms, kind) => {
      if (ms >= remaining() || controller.signal.aborted) {
        throw new WaveApiError(kind, "Wave retry exceeds request deadline.");
      }
      await sleepFn(ms);
    }};

  const requestBody = JSON.stringify({query, variables});
  const requestHeaders = {
    "Authorization": `Bearer ${token}`,
    "Content-Type": "application/json",
  };

  let timer;
  const expired = new Promise((resolve, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new WaveApiError("network", "Wave request deadline exceeded."));
    }, remaining());
  });
  try {
    const request = postWithRetry(requestBody, requestHeaders, fetchImpl,
        maxRetries, budget).then(parseGraphqlResponse);
    return await Promise.race([request, expired]);
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}

// ---------------------------------------------------------------------------
// Helpers built on graphql()
// ---------------------------------------------------------------------------

/**
 * Fetches the authenticated Wave user's id and default email, used to
 * fast-fail an invalid or missing token.
 * @param {Object=} options Injectable options (see `graphql`).
 * @return {!Promise<Object>} The user object with id and defaultEmail.
 */
async function whoami(options = {}) {
  const data = await graphql(
      "query { user { id defaultEmail } }",
      {},
      options,
  );
  // A 200 with no data.user is an off-spec response — throw a typed
  // WaveApiError here instead of letting `undefined.user` blow up raw.
  if (data == null || data.user == null) {
    throw new WaveApiError(
        "unknown",
        "Wave API /whoami returned a 200 but no user object in data.",
        {data},
    );
  }
  return data.user;
}

/**
 * Lists the first page (up to 50) of Wave businesses for the token owner as
 * an array of `{id, name}` objects.
 * @param {Object=} options Injectable options (see `graphql`).
 * @return {!Promise<!Array<Object>>} Business nodes with id and name.
 */
async function listBusinesses(options = {}) {
  const data = await graphql(
      "{ businesses(page: 1, pageSize: 50)" +
      " { edges { node { id name } } } }",
      {},
      options,
  );
  const edges = (data.businesses && Array.isArray(data.businesses.edges)) ?
    data.businesses.edges : [];
  return edges
      .filter((e) => e && e.node)
      // Coerce a null/non-string name to "" so an off-spec node doesn't blow
      // up downstream name matching (selectBusiness) when it calls
      // `name.trim()`.
      .map((e) => ({
        id: e.node.id,
        name: typeof e.node.name === "string" ? e.node.name : "",
      }));
}

module.exports = {WaveApiError, graphql, whoami, listBusinesses};
