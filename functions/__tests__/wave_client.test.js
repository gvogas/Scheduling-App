"use strict";

const {WaveApiError, graphql, whoami, listBusinesses} =
  require("../wave/client");

// ---------------------------------------------------------------------------
// Shared test helpers
// ---------------------------------------------------------------------------

// No-op sleep so retry tests complete instantly.
const noopSleep = () => Promise.resolve();

/**
 * Builds a minimal options bag with a token, fetchImpl, and sleepFn already
 * injected, so tests never touch a real secret or the network.
 * @param {function} fetchImpl Mock fetch implementation.
 * @param {object=} extra Extra overrides merged into options.
 * @return {object}
 */
function opts(fetchImpl, extra = {}) {
  return {token: "test-token", fetchImpl, sleepFn: noopSleep, ...extra};
}

/**
 * Creates a mock Response-like object.
 * @param {number} status HTTP status code.
 * @param {*} body Value returned by `.json()`.
 * @param {object=} headers Optional header key→value map.
 * @return {object}
 */
function mockResponse(status, body, headers = {}) {
  return {
    status,
    headers: {
      get: (name) => headers[name.toLowerCase()] || null,
    },
    json: () => Promise.resolve(body),
  };
}

/**
 * Returns a fetch mock that returns each response from `responses` in order,
 * repeating the last one forever once the array is exhausted.
 * @param {...object} responses Response objects to return in sequence.
 * @return {function(): Promise<object>}
 */
function sequencedFetch(...responses) {
  let i = 0;
  return () => {
    const r = responses[Math.min(i, responses.length - 1)];
    i++;
    return Promise.resolve(r);
  };
}

// ---------------------------------------------------------------------------
// graphql() — success path
// ---------------------------------------------------------------------------

describe("graphql() request deadlines", () => {
  afterEach(() => jest.useRealTimers());

  test.each(["fetch", "json", "discard"])("bounds a stalled %s",
      async (phase) => {
        jest.useFakeTimers();
        const stalled = new Promise(() => {});
        const response = phase === "discard" ?
      {status: 503, text: () => stalled} :
      {status: 200, json: () => stalled};
        const fetch = jest.fn().mockReturnValue(
        phase === "fetch" ? stalled : Promise.resolve(response));
        const pending = graphql("query { ok }", {}, opts(fetch, {
          requestTimeoutMs: 100,
        }));
        const rejected = expect(pending).rejects
            .toMatchObject({kind: "network"});
        await jest.advanceTimersByTimeAsync(100);
        await rejected;
        expect(fetch.mock.calls[0][1].signal.aborted).toBe(true);
      });

  test("a retry exceeding the drain budget stays retryable without sleeping",
      async () => {
        const fetch = jest.fn().mockResolvedValue(
            mockResponse(429, null, {"retry-after": "60"}));
        const sleepFn = jest.fn();
        await expect(graphql("query { ok }", {}, opts(fetch, {
          sleepFn, deadlineMs: Date.now() + 5000,
        }))).rejects.toMatchObject({kind: "rateLimited"});
        expect(sleepFn).not.toHaveBeenCalled();
        expect(fetch).toHaveBeenCalledTimes(1);
      });
});

describe("graphql() success", () => {
  test("returns data on HTTP 200 with no errors", async () => {
    const body = {data: {user: {id: "u1", defaultEmail: "a@b.com"}}};
    const fetch = jest.fn().mockResolvedValue(mockResponse(200, body));
    const result = await graphql("query { user { id } }", {}, opts(fetch));
    expect(result).toEqual(body.data);
  });

  test("sends Authorization Bearer header", async () => {
    const fetch = jest.fn().mockResolvedValue(
        mockResponse(200, {data: {}}),
    );
    await graphql("query { user { id } }", {}, opts(fetch));
    const [, init] = fetch.mock.calls[0];
    expect(init.headers["Authorization"]).toBe("Bearer test-token");
  });

  test("sends Content-Type application/json header", async () => {
    const fetch = jest.fn().mockResolvedValue(
        mockResponse(200, {data: {}}),
    );
    await graphql("query { user { id } }", {}, opts(fetch));
    const [, init] = fetch.mock.calls[0];
    expect(init.headers["Content-Type"]).toBe("application/json");
  });

  test("serializes query AND variables into the body", async () => {
    const fetch = jest.fn().mockResolvedValue(
        mockResponse(200, {data: {}}),
    );
    const vars = {businessId: "biz1", name: "Acme"};
    await graphql("mutation { foo }", vars, opts(fetch));
    const [, init] = fetch.mock.calls[0];
    const sent = JSON.parse(init.body);
    expect(sent.query).toBe("mutation { foo }");
    expect(sent.variables).toEqual(vars);
  });

  test("variables are NOT string-interpolated into the query", async () => {
    const fetch = jest.fn().mockResolvedValue(
        mockResponse(200, {data: {}}),
    );
    const vars = {name: "injected-value"};
    await graphql("mutation { createCustomer }", vars, opts(fetch));
    const [, init] = fetch.mock.calls[0];
    const sent = JSON.parse(init.body);
    // The query string must not contain the variable value.
    expect(sent.query).not.toContain("injected-value");
    // The value must be in variables, not baked into query.
    expect(sent.variables.name).toBe("injected-value");
  });
});

// ---------------------------------------------------------------------------
// graphql() — 429 retry
// ---------------------------------------------------------------------------

describe("graphql() 429 retry", () => {
  test("429 then 200 → succeeds after one retry", async () => {
    const successBody = {data: {ok: true}};
    const fetch = sequencedFetch(
        mockResponse(429, null),
        mockResponse(200, successBody),
    );
    const mockFetch = jest.fn(fetch);
    const result = await graphql(
        "query { ok }",
        {},
        opts(mockFetch, {maxRetries: 3}),
    );
    expect(result).toEqual(successBody.data);
    expect(mockFetch).toHaveBeenCalledTimes(2);
  });

  test("429 persisting → throws WaveApiError kind rateLimited", async () => {
    const alwaysRateLimited = jest.fn().mockResolvedValue(
        mockResponse(429, null),
    );
    await expect(
        graphql("query { ok }", {}, opts(alwaysRateLimited, {maxRetries: 2})),
    ).rejects.toMatchObject({kind: "rateLimited"});
    // Initial attempt + maxRetries retries = maxRetries + 1 calls.
    expect(alwaysRateLimited).toHaveBeenCalledTimes(3);
  });

  test("429 with Retry-After header → delay uses header value", async () => {
    const delays = [];
    const sleepSpy = (ms) => {
      delays.push(ms);
      return Promise.resolve();
    };
    const fetch = sequencedFetch(
        mockResponse(429, null, {"retry-after": "2"}),
        mockResponse(200, {data: {}}),
    );
    await graphql(
        "query { ok }",
        {},
        {
          token: "t",
          fetchImpl: jest.fn(fetch),
          sleepFn: sleepSpy,
          maxRetries: 1,
        },
    );
    expect(delays.length).toBe(1);
    expect(delays[0]).toBe(2000); // 2 seconds in ms
  });

  // Regression test for fix #2: a Retry-After of 3600 should get clamped
  // down to 60000 ms.
  test("Fix#2: Retry-After:3600 is clamped to 60000 ms", async () => {
    const delays = [];
    const sleepSpy = (ms) => {
      delays.push(ms);
      return Promise.resolve();
    };
    const fetch = sequencedFetch(
        mockResponse(429, null, {"retry-after": "3600"}),
        mockResponse(200, {data: {}}),
    );
    await graphql(
        "query { ok }",
        {},
        {
          token: "t",
          fetchImpl: jest.fn(fetch),
          sleepFn: sleepSpy,
          maxRetries: 1,
          requestTimeoutMs: 120_000,
        },
    );
    expect(delays.length).toBe(1);
    // 3600 s is 3,600,000 ms, but we clamp it down to 60,000 ms.
    expect(delays[0]).toBe(60000);
    expect(delays[0]).not.toBe(3600000);
  });

  // Regression test for fix #4: a Retry-After of 0 should be honored as
  // 0 ms, not fall through to jittered backoff, which always waits at
  // least 250 ms.
  test("Fix#4: Retry-After:0 is honored as 0 ms, not treated as absent",
      async () => {
        const delays = [];
        const sleepSpy = (ms) => {
          delays.push(ms);
          return Promise.resolve();
        };
        const fetch = sequencedFetch(
            mockResponse(429, null, {"retry-after": "0"}),
            mockResponse(200, {data: {}}),
        );
        await graphql(
            "query { ok }",
            {},
            {
              token: "t",
              fetchImpl: jest.fn(fetch),
              sleepFn: sleepSpy,
              maxRetries: 1,
            },
        );
        expect(delays.length).toBe(1);
        // Should be exactly 0 since the header is honored, not a backoff
        // value.
        expect(delays[0]).toBe(0);
      });
});

// ---------------------------------------------------------------------------
// graphql() — 5xx retry
// ---------------------------------------------------------------------------

describe("graphql() 5xx retry", () => {
  test("5xx then 200 → retries and succeeds", async () => {
    const successBody = {data: {value: 42}};
    const fetch = sequencedFetch(
        mockResponse(503, null),
        mockResponse(200, successBody),
    );
    const mockFetch = jest.fn(fetch);
    const result = await graphql(
        "query { value }",
        {},
        opts(mockFetch, {maxRetries: 2}),
    );
    expect(result).toEqual(successBody.data);
    expect(mockFetch).toHaveBeenCalledTimes(2);
  });

  test("5xx persisting → throws WaveApiError kind network", async () => {
    const always500 = jest.fn().mockResolvedValue(mockResponse(500, null));
    await expect(
        graphql("query { ok }", {}, opts(always500, {maxRetries: 2})),
    ).rejects.toMatchObject({kind: "network"});
    expect(always500).toHaveBeenCalledTimes(3);
  });
});

// ---------------------------------------------------------------------------
// graphql() — network (fetch rejection) retry
// ---------------------------------------------------------------------------

describe("graphql() network error retry", () => {
  test("fetch rejects then resolves → retries and succeeds", async () => {
    const successBody = {data: {done: true}};
    let call = 0;
    const fetchMock = jest.fn(() => {
      call++;
      if (call === 1) return Promise.reject(new Error("ECONNRESET"));
      return Promise.resolve(mockResponse(200, successBody));
    });
    const result = await graphql(
        "query { done }",
        {},
        opts(fetchMock, {maxRetries: 2}),
    );
    expect(result).toEqual(successBody.data);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test("fetch rejects persistently → throws WaveApiError kind network",
      async () => {
        const netErr = jest.fn().mockRejectedValue(new Error("ETIMEDOUT"));
        await expect(
            graphql("query { ok }", {}, opts(netErr, {maxRetries: 2})),
        ).rejects.toMatchObject({kind: "network"});
        expect(netErr).toHaveBeenCalledTimes(3);
      });
});

// ---------------------------------------------------------------------------
// graphql() — auth errors (no retry)
// ---------------------------------------------------------------------------

describe("graphql() auth errors", () => {
  test("401 → throws WaveApiError kind auth and does NOT retry", async () => {
    const fetch401 = jest.fn().mockResolvedValue(mockResponse(401, null));
    await expect(
        graphql("query { ok }", {}, opts(fetch401, {maxRetries: 3})),
    ).rejects.toMatchObject({kind: "auth"});
    expect(fetch401).toHaveBeenCalledTimes(1);
  });

  test("403 → throws WaveApiError kind auth and does NOT retry", async () => {
    const fetch403 = jest.fn().mockResolvedValue(mockResponse(403, null));
    await expect(
        graphql("query { ok }", {}, opts(fetch403, {maxRetries: 3})),
    ).rejects.toMatchObject({kind: "auth"});
    expect(fetch403).toHaveBeenCalledTimes(1);
  });
});

// ---------------------------------------------------------------------------
// graphql() — GraphQL-layer errors
// ---------------------------------------------------------------------------

describe("graphql() GraphQL errors", () => {
  test("200 with non-empty errors array → throws WaveApiError kind graphql",
      async () => {
        const body = {
          data: null,
          errors: [{message: "Not found"}, {message: "Bad input"}],
        };
        const fetch = jest.fn().mockResolvedValue(mockResponse(200, body));
        const err = await graphql(
            "query { ok }",
            {},
            opts(fetch),
        ).catch((e) => e);
        expect(err).toBeInstanceOf(WaveApiError);
        expect(err.kind).toBe("graphql");
        expect(err.details).toEqual(body.errors);
      });

  test("200 with empty errors array → succeeds (not a GraphQL error)",
      async () => {
        const body = {data: {ok: true}, errors: []};
        const fetch = jest.fn().mockResolvedValue(mockResponse(200, body));
        const result = await graphql("query { ok }", {}, opts(fetch));
        expect(result).toEqual(body.data);
      });
});

// ---------------------------------------------------------------------------
// graphql() — Fix #3: non-object 200 body guard
// ---------------------------------------------------------------------------

describe("graphql() non-object 200 body (Fix #3)", () => {
  test("200 with JSON-null body throws WaveApiError kind unknown",
      async () => {
        const fetch = jest.fn().mockResolvedValue(mockResponse(200, null));
        const err = await graphql(
            "query { ok }",
            {},
            opts(fetch, {maxRetries: 0}),
        ).catch((e) => e);
        expect(err).toBeInstanceOf(WaveApiError);
        expect(err.kind).toBe("unknown");
        // Must NOT be a raw TypeError from null.errors access
        expect(err.constructor.name).not.toBe("TypeError");
      });

  test("200 with JSON-array body throws WaveApiError kind unknown",
      async () => {
        const fetch = jest.fn().mockResolvedValue(
            mockResponse(200, ["not", "an", "object"]),
        );
        const err = await graphql(
            "query { ok }",
            {},
            opts(fetch, {maxRetries: 0}),
        ).catch((e) => e);
        expect(err).toBeInstanceOf(WaveApiError);
        expect(err.kind).toBe("unknown");
        expect(err.constructor.name).not.toBe("TypeError");
      });
});

// ---------------------------------------------------------------------------
// graphql() — unknown status
// ---------------------------------------------------------------------------

describe("graphql() unknown status", () => {
  test("302 → throws WaveApiError kind unknown", async () => {
    const fetch302 = jest.fn().mockResolvedValue(mockResponse(302, null));
    await expect(
        graphql("query { ok }", {}, opts(fetch302, {maxRetries: 0})),
    ).rejects.toMatchObject({kind: "unknown"});
  });
});

// ---------------------------------------------------------------------------
// WaveApiError shape
// ---------------------------------------------------------------------------

describe("WaveApiError", () => {
  test("is an instance of Error", () => {
    const e = new WaveApiError("auth", "token invalid", 401);
    expect(e).toBeInstanceOf(Error);
    expect(e).toBeInstanceOf(WaveApiError);
  });

  test("exposes kind and details fields", () => {
    const details = [{message: "oops"}];
    const e = new WaveApiError("graphql", "oops", details);
    expect(e.kind).toBe("graphql");
    expect(e.details).toBe(details);
    expect(e.message).toBe("oops");
  });
});

// ---------------------------------------------------------------------------
// whoami()
// ---------------------------------------------------------------------------

describe("whoami()", () => {
  test("calls graphql with the user query and returns the user object",
      async () => {
        const user = {id: "usr1", defaultEmail: "admin@example.com"};
        const fetch = jest.fn().mockResolvedValue(
            mockResponse(200, {data: {user}}),
        );
        const result = await whoami(opts(fetch));
        expect(result).toEqual(user);
        const [, init] = fetch.mock.calls[0];
        const sent = JSON.parse(init.body);
        expect(sent.query).toContain("user");
        expect(sent.query).toContain("id");
        expect(sent.query).toContain("defaultEmail");
      });

  // Regression test for fix #1: an off-spec 200 should throw a
  // WaveApiError, not a raw TypeError.
  test("Fix#1: 200 with {data:{}} (no user) throws WaveApiError kind unknown",
      async () => {
        const fetch = jest.fn().mockResolvedValue(
            mockResponse(200, {data: {}}),
        );
        const err = await whoami(opts(fetch)).catch((e) => e);
        expect(err).toBeInstanceOf(WaveApiError);
        expect(err.kind).toBe("unknown");
        // Must NOT be a raw TypeError
        expect(err.constructor.name).not.toBe("TypeError");
      });

  test("Fix#1: 200 with {data:null} throws WaveApiError kind unknown",
      async () => {
        const fetch = jest.fn().mockResolvedValue(
            mockResponse(200, {data: null}),
        );
        const err = await whoami(opts(fetch)).catch((e) => e);
        expect(err).toBeInstanceOf(WaveApiError);
        expect(err.kind).toBe("unknown");
        expect(err.constructor.name).not.toBe("TypeError");
      });
});

// ---------------------------------------------------------------------------
// listBusinesses()
// ---------------------------------------------------------------------------

describe("listBusinesses()", () => {
  test("returns array of {id, name} nodes", async () => {
    const edges = [
      {node: {id: "biz1", name: "Alpha Co"}},
      {node: {id: "biz2", name: "Beta LLC"}},
    ];
    const fetch = jest.fn().mockResolvedValue(
        mockResponse(200, {data: {businesses: {edges}}}),
    );
    const result = await listBusinesses(opts(fetch));
    expect(result).toEqual([
      {id: "biz1", name: "Alpha Co"},
      {id: "biz2", name: "Beta LLC"},
    ]);
  });

  test("calls graphql with the businesses query", async () => {
    const fetch = jest.fn().mockResolvedValue(
        mockResponse(200, {data: {businesses: {edges: []}}}),
    );
    await listBusinesses(opts(fetch));
    const [, init] = fetch.mock.calls[0];
    const sent = JSON.parse(init.body);
    expect(sent.query).toContain("businesses");
    expect(sent.query).toContain("edges");
    expect(sent.query).toContain("node");
  });

  test("returns empty array when edges is empty", async () => {
    const fetch = jest.fn().mockResolvedValue(
        mockResponse(200, {data: {businesses: {edges: []}}}),
    );
    const result = await listBusinesses(opts(fetch));
    expect(result).toEqual([]);
  });

  test("coerces a null/missing business name to empty string", async () => {
    const edges = [
      {node: {id: "biz1", name: null}},
      {node: {id: "biz2"}},
    ];
    const fetch = jest.fn().mockResolvedValue(
        mockResponse(200, {data: {businesses: {edges}}}),
    );
    const result = await listBusinesses(opts(fetch));
    expect(result).toEqual([
      {id: "biz1", name: ""},
      {id: "biz2", name: ""},
    ]);
  });

  test("does not pass variable values interpolated into the query string",
      async () => {
        const fetch = jest.fn().mockResolvedValue(
            mockResponse(200, {data: {businesses: {edges: []}}}),
        );
        await listBusinesses(opts(fetch));
        const [, init] = fetch.mock.calls[0];
        const sent = JSON.parse(init.body);
        // page/pageSize are literal pagination constants, not user data.
        // This test only checks that *variable* values aren't interpolated.
        expect(Object.keys(sent.variables)).toHaveLength(0);
      });
});

// ---------------------------------------------------------------------------
// graphql() — non-2xx response bodies are drained (socket release, F10a)
// ---------------------------------------------------------------------------

describe("graphql() drains non-2xx response bodies", () => {
  /**
   * mockResponse variant that records `.text()` consumption.
   * @param {number} status HTTP status code.
   * @param {*} body Value returned by `.json()`.
   * @param {object=} headers Optional header key→value map.
   * @return {object} Response double with a jest-tracked `text`.
   */
  function drainableResponse(status, body, headers = {}) {
    return {
      status,
      headers: {get: (name) => headers[name.toLowerCase()] || null},
      json: () => Promise.resolve(body),
      text: jest.fn(() => Promise.resolve("")),
    };
  }

  test("429 retry path consumes the body of each rate-limited response",
      async () => {
        const limited = drainableResponse(429, {});
        const ok = drainableResponse(200, {data: {ok: true}});
        const fetch = sequencedFetch(limited, ok);
        await graphql("query { x }", {}, opts(fetch));
        expect(limited.text).toHaveBeenCalledTimes(1);
        // The success body is consumed via json(), not text().
        expect(ok.text).not.toHaveBeenCalled();
      });

  test("5xx retry path consumes each failed response body", async () => {
    const err1 = drainableResponse(502, {});
    const err2 = drainableResponse(503, {});
    const ok = drainableResponse(200, {data: {}});
    const fetch = sequencedFetch(err1, err2, ok);
    await graphql("query { x }", {}, opts(fetch));
    expect(err1.text).toHaveBeenCalledTimes(1);
    expect(err2.text).toHaveBeenCalledTimes(1);
  });

  test("terminal 401 consumes the body before throwing", async () => {
    const denied = drainableResponse(401, {});
    const fetch = sequencedFetch(denied);
    await expect(graphql("query { x }", {}, opts(fetch)))
        .rejects.toMatchObject({kind: "auth"});
    expect(denied.text).toHaveBeenCalledTimes(1);
  });

  test("unexpected non-2xx consumes the body before throwing", async () => {
    const odd = drainableResponse(302, {});
    const fetch = sequencedFetch(odd);
    await expect(graphql("query { x }", {}, opts(fetch)))
        .rejects.toMatchObject({kind: "unknown"});
    expect(odd.text).toHaveBeenCalledTimes(1);
  });

  test("a response double WITHOUT .text still works (no throw)", async () => {
    // mockResponse doesn't define .text() here, so the drain step needs to
    // tolerate that.
    const fetch = sequencedFetch(
        mockResponse(500, {}),
        mockResponse(200, {data: {fine: true}}),
    );
    const result = await graphql("query { x }", {}, opts(fetch));
    expect(result).toEqual({fine: true});
  });

  test("a rejecting .text() is swallowed", async () => {
    const bad = {
      status: 500,
      headers: {get: () => null},
      json: () => Promise.resolve({}),
      text: jest.fn(() => Promise.reject(new Error("stream destroyed"))),
    };
    const fetch = sequencedFetch(bad, mockResponse(200, {data: {}}));
    await expect(graphql("query { x }", {}, opts(fetch)))
        .resolves.toEqual({});
  });
});
