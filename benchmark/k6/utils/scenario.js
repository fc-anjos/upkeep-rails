// Shared scenario runner for upkeep and turbo benchmark scripts.
//
// Each scenario file defines a config object and calls runScenario().
// This module handles: login, page GET, token extraction, WS connect,
// subscribe, writer/reader loop, disconnect.

import { check, sleep, fail } from "k6";
import http from "k6/http";
import cable from "k6/x/cable";
import { Trend, Counter } from "k6/metrics";
import { randomIntBetween, findBetween } from "./index.js";
import { login, cookieString, extractCsrfToken } from "./auth.js";
import { textSummary } from "./summary.js";
import { isWriterVu } from "./writers.js";
import { extractCableApplicationMessage, isApplicationMessage } from "./messages.js";
import { drainPendingDeliveries } from "./delivery_ack.js";

// ── Shared metrics (every scenario uses these) ─────────────────────────

export const rtt = new Trend("rtt", true);
export const suback = new Trend("suback", true);
export const payloadBytes = new Trend("payload_bytes", true);
export const pageRender = new Trend("page_render", true);
export const loginLatency = new Trend("login_latency", true);
export const setupTotal = new Trend("setup_total", true);
export const broadcastsRcvd = new Counter("broadcasts_rcvd");

// ── Helpers ────────────────────────────────────────────────────────────

function measurePayload(msg) {
  const appMessage = extractCableApplicationMessage(msg);
  if (appMessage === null) return null;

  const data = typeof appMessage === "string" ? appMessage : JSON.stringify(appMessage);
  payloadBytes.add(data.length);
  broadcastsRcvd.add(1);
  return { payload: appMessage, serialized: data };
}

function receiveRelevantMessage(sub, _channelName, timeoutSeconds) {
  const deadline = Date.now() + timeoutSeconds * 1000;

  while (Date.now() < deadline) {
    const received = sub.receive();
    if (!received) return null;
    if (isApplicationMessage(received)) return received;
  }

  return null;
}

function benchHeader(res, name) {
  const value = res.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

function loadPageAndToken(baseUrl, pagePath, jar, channel) {
  const renderStart = Date.now();
  const pageRes = http.get(`${baseUrl}${pagePath}`, { jar });
  pageRender.add(Date.now() - renderStart);
  check(pageRes, { "page loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, `${channel.tokenAttr}="`, '"');
  if (!token) {
    console.error(`[diag] token-missing VU=${__VU} path=${pagePath} status=${pageRes.status} len=${(pageRes.body||"").length} ct=${pageRes.headers["Content-Type"]||""} loc=${pageRes.headers["Location"]||""}`);
    console.error(`[diag] body-head: ${(pageRes.body||"").slice(0, 400).replace(/\n/g, " ")}`);
    console.error(`[diag] body-tail: ${(pageRes.body||"").slice(-400).replace(/\n/g, " ")}`);
    fail(`Could not extract ${channel.tokenAttr} from page`);
  }

  const csrfToken = extractCsrfToken(pageRes.body);
  if (!csrfToken) fail("Could not extract CSRF token from page");

  return {
    token,
    csrfToken,
    requestId: benchHeader(pageRes, "X-Bench-Request-Id"),
  };
}

function benchConnectId(label = "primary") {
  return `${label}-vu${__VU}-${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
}

function wsUrlWithBenchConnectId(wsUrl, connectId) {
  const joiner = wsUrl.includes("?") ? "&" : "?";
  return `${wsUrl}${joiner}bench_connect_id=${encodeURIComponent(connectId)}`;
}

function connectSubscription(wsUrl, baseUrl, jar, channel, token, wsTimeout, connectId) {
  const client = cable.connect(wsUrlWithBenchConnectId(wsUrl, connectId), {
    receiveTimeoutMs: wsTimeout,
    cookies: cookieString(jar, baseUrl),
  });
  if (!check(client, { connected: (c) => c })) fail("WebSocket connection failed");

  const sub = client.subscribe(channel.name, {
    [channel.paramKey]: token,
    bench_connect_id: connectId,
  });
  if (!check(sub, { subscribed: (ch) => ch })) fail("Subscription failed");
  suback.add(sub.ackDuration());

  return { client, sub, connectId };
}

export function establishScenarioContext(config) {
  const {
    baseUrl, wsUrl, numUsers, pagePath, channel, wsTimeout = 15000,
    writerRatio = 10,
    writerStartVu = 1,
    initialDelaySeconds = 0,
    initialJitter = true,
  } = config;

  const userIdx = (__VU % numUsers) + 1;
  const email = `user${userIdx}@bench.test`;
  const writer = isWriterVu(__VU, writerRatio, writerStartVu);

  if (initialDelaySeconds > 0) sleep(initialDelaySeconds);
  if (initialJitter) sleep(randomIntBetween(1, 10) / 10);

  const setupStartedAt = Date.now();
  const loginStartedAt = Date.now();
  const jar = login(baseUrl, email, "benchpass123");
  loginLatency.add(Date.now() - loginStartedAt);

  const primary = loadPageAndToken(baseUrl, pagePath, jar, channel);
  const csrfToken = primary.csrfToken;
  const primaryConnectId = benchConnectId("primary");
  const { client, sub } = connectSubscription(
    wsUrl,
    baseUrl,
    jar,
    channel,
    primary.token,
    wsTimeout,
    primaryConnectId
  );

  let observerClient = null;
  let observerSub = null;
  let observerConnectId = null;
  if (writer && config.writerObserver === "sibling_endpoint") {
    const observer = loadPageAndToken(baseUrl, pagePath, jar, channel);
    observerConnectId = benchConnectId("observer");
    const observerConn = connectSubscription(
      wsUrl,
      baseUrl,
      jar,
      channel,
      observer.token,
      wsTimeout,
      observerConnectId
    );
    observerClient = observerConn.client;
    observerSub = observerConn.sub;
  }

  setupTotal.add(Date.now() - setupStartedAt);

  return {
    jar,
    baseUrl,
    csrfToken,
    sub,
    observerSub,
    client,
    observerClient,
    config,
    writer,
    primaryRequestId: primary.requestId,
    primaryConnectId,
    observerConnectId,
    setupCompletedAt: Date.now(),
  };
}

export function disconnectScenarioContext(ctx) {
  drainPendingDeliveries(ctx.observerSub, ctx.config.channel);
  drainPendingDeliveries(ctx.sub, ctx.config.channel);
  ctx.observerClient && ctx.observerClient.disconnect();
  ctx.client.disconnect();
}

export function runScenarioIterations(ctx, config) {
  const {
    iterations,
    channel,
    wsTimeout = 15000,
    awaitWriterMessage = true,
    writerReceiveTimeoutSeconds = wsTimeout / 1000,
  } = config;

  for (let i = 0; i < iterations; i++) {
    if (ctx.writer) {
      drainPendingDeliveries(ctx.sub, channel);
      drainPendingDeliveries(ctx.observerSub, channel);

      const { sendTs } = config.onWrite(ctx, i);

      if (awaitWriterMessage) {
        const targetSub = ctx.observerSub || ctx.sub;
        const received = receiveRelevantMessage(targetSub, channel.name, writerReceiveTimeoutSeconds);
        if (received) {
          const measured = measurePayload(received);
          if (!measured) continue;
          drainPendingDeliveries(ctx.sub, channel);
          drainPendingDeliveries(ctx.observerSub, channel);
          if (config.onWriterReceive) {
            config.onWriterReceive(ctx, measured.payload, sendTs, measured.serialized);
          } else {
            rtt.add(Date.now() - sendTs);
          }
        }
      }
    } else {
      sleep(randomIntBetween(5, 15) / 100);
      const applicationMessages = drainPendingDeliveries(ctx.sub, channel, 1);
      if (config.onReaderReceive) {
        config.onReaderReceive(ctx, applicationMessages);
      } else {
        for (const msg of applicationMessages) {
          const measured = measurePayload(msg);
          if (!measured) continue;
        }
      }
    }

    sleep(randomIntBetween(3, 8) / 10);
  }
}

// ── Core runner ────────────────────────────────────────────────────────

// config shape:
// {
//   baseUrl, wsUrl, numUsers, iterations,
//   pagePath,                        // e.g. "/boards/1" or "/rooms/1"
//   channel: {                       // subscription setup
//     name,                          // "Upkeep::Rails::Channel" or "Turbo::StreamsChannel"
//     tokenAttr,                     // "data-context-token" or "signed-stream-name"
//     paramKey,                      // "context_token" or "signed_stream_name"
//   },
//   wsTimeout,                       // receiveTimeoutMs (default 15000)
//   writerRatio,                     // 1-in-N VUs are writers (e.g. 10 = 10%, 20 = 5%)
//   onWrite(ctx, i),                 // called per writer iteration, returns { sendTs }
//   onWriterReceive(ctx, msg, sendTs), // called when writer gets a WS message
//   onReaderReceive(ctx, msgs),      // called when reader gets WS messages (optional)
//   extraMetrics,                    // { name: Trend|Counter } — scenario-specific metrics
// }
export function runScenario(config) {
  const ctx = establishScenarioContext(config);
  try {
    runScenarioIterations(ctx, config);
  } finally {
    disconnectScenarioContext(ctx);
  }
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
