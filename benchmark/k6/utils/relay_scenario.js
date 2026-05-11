// Shared scenario runner for upkeep benchmark scripts. Each fixture
// defines a config object and calls `runRelayScenario`; this module
// handles login, page GET, token extraction, raw WS connect to the
// relay, scheduled writer/reader behavior, and disconnect.
//
// The relay sends binary msgpack envelopes; this helper counts frames
// rather than decoding payloads. Fixtures that need to time RTT can
// provide `onWrite` (returns sendTs) and the helper records the delta
// when the next binary frame arrives.

import { check, fail } from "k6";
import http from "k6/http";
import ws from "k6/ws";
import { Trend, Counter } from "k6/metrics";
import { findBetween, randomIntBetween } from "./index.js";
import { login, extractCsrfToken } from "./auth.js";
import { textSummary } from "./summary.js";
import { isWriterVu } from "./writers.js";

export const rtt = new Trend("rtt", true);
export const payloadBytes = new Trend("payload_bytes", true);
export const pageRender = new Trend("page_render", true);
export const loginLatency = new Trend("login_latency", true);
export const setupTotal = new Trend("setup_total", true);
export const broadcastsRcvd = new Counter("broadcasts_rcvd");

export function loadPageAndToken(baseUrl, pagePath, jar) {
  const renderStart = Date.now();
  const pageRes = http.get(`${baseUrl}${pagePath}`, { jar });
  pageRender.add(Date.now() - renderStart);
  check(pageRes, { "page loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!token) fail(`could not extract context_token from ${pagePath}`);

  const csrfToken = extractCsrfToken(pageRes.body);
  return { token, csrfToken, body: pageRes.body };
}

export function relayWsUrl(wsUrl, token) {
  const joiner = wsUrl.includes("?") ? "&" : "?";
  return `${wsUrl}${joiner}token=${encodeURIComponent(token)}`;
}

// Open a WS connection to dispatch and run the supplied callback
// inside k6's blocking ws callback. The callback receives the socket
// plus a `pendingFrames()` accessor that drains the count of binary
// frames received since last call.
export function withRelaySocket(wsUrl, token, fn) {
  const url = relayWsUrl(wsUrl, token);
  let pending = 0;
  const result = ws.connect(url, {}, function (sock) {
    sock.on("binaryMessage", function (data) {
      pending += 1;
      payloadBytes.add(data.byteLength || 0);
      broadcastsRcvd.add(1);
    });
    // Keep the timer wheel alive — k6/ws only fires scheduled timers
    // while at least one is registered.
    sock.setInterval(function () {}, 1000);

    fn(sock, () => {
      const n = pending;
      pending = 0;
      return n;
    });
  });
  check(result, { "ws connected": (r) => r && r.status === 101 });
  return result;
}

// runRelayScenario: writer/reader iteration loop. Same config shape
// as the turbo-side `scenario.js`.
//
// config:
//   baseUrl, wsUrl, numUsers, iterations, pagePath
//   wsTimeoutMs (default 20000): cap on the whole VU iteration
//   writerRatio: 1-in-N VUs are writers
//   onWrite(ctx, i): called once per writer iteration; returns { sendTs }
//   onWriterReceive(ctx, sendTs): optional; default records rtt
export function runRelayScenario(config) {
  const {
    baseUrl, wsUrl, numUsers, iterations, pagePath,
    wsTimeoutMs = 20000,
    writerRatio = 10,
    writerStartVu = 1,
    iterationDelayMs = 500,
  } = config;

  const userIdx = (__VU % numUsers) + 1;
  const email = `user${userIdx}@bench.test`;
  const writer = isWriterVu(__VU, writerRatio, writerStartVu);

  const setupStartedAt = Date.now();
  const loginStartedAt = Date.now();
  const jar = login(baseUrl, email, "benchpass123");
  loginLatency.add(Date.now() - loginStartedAt);

  const { token, csrfToken } = loadPageAndToken(baseUrl, pagePath, jar);
  setupTotal.add(Date.now() - setupStartedAt);

  withRelaySocket(wsUrl, token, function (sock, drainPending) {
    const ctx = { jar, baseUrl, csrfToken, writer, config };

    if (writer) {
      let i = 0;
      let lastSendTs = null;

      const fireOnce = function () {
        if (i >= iterations) {
          sock.setTimeout(function () { sock.close(); }, 2000);
          return;
        }
        const writeIndex = i++;
        drainPending();
        const result = config.onWrite(ctx, writeIndex);
        if (result && typeof result.sendTs === "number") {
          lastSendTs = result.sendTs;
        }
        sock.setTimeout(fireOnce, iterationDelayMs);
      };

      sock.on("binaryMessage", function () {
        if (lastSendTs !== null) {
          if (config.onWriterReceive) {
            config.onWriterReceive(ctx, lastSendTs);
          } else {
            rtt.add(Date.now() - lastSendTs);
          }
          lastSendTs = null;
        }
      });

      sock.setTimeout(fireOnce, iterationDelayMs);
    } else {
      let i = 0;
      const tick = function () {
        if (i >= iterations) {
          sock.setTimeout(function () { sock.close(); }, 2000);
          return;
        }
        i += 1;
        drainPending();
        sock.setTimeout(tick, iterationDelayMs + randomIntBetween(0, 200));
      };
      sock.setTimeout(tick, iterationDelayMs);
    }

    sock.setTimeout(function () { sock.close(); }, wsTimeoutMs);
  });
}

export function buildHandleSummary(outputPath) {
  return function handleSummary(data) {
    const targetPath = __ENV.K6_SUMMARY_PATH || outputPath;
    return {
      stdout: textSummary(data, { indent: " ", enableColors: true }),
      [targetPath]: JSON.stringify(data),
    };
  };
}
