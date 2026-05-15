// Identity-free shared feed comparison workload for Turbo.
//
// Mirrors the Upkeep workload against the existing `/feed` surface
// without a login/session. Turbo broadcasts a refresh ping for each
// FeedItem write, then every subscriber performs the page GET that a
// browser would issue after a Turbo refresh.

import http from "k6/http";
import { check, fail, sleep } from "k6";
import cable from "k6/x/cable";
import exec from "k6/execution";
import { Counter, Trend } from "k6/metrics";
import { BASE_URL, WS_URL, warmSetupAdmissionForVu, warmSetupWindowMs } from "../utils/config.js";
import { findBetween } from "../utils/index.js";
import { isApplicationMessage } from "../utils/messages.js";
import { textSummary } from "../utils/summary.js";

const pageRender = new Trend("page_render", true);
const postLatency = new Trend("post_latency", true);
const refreshGetLatency = new Trend("refresh_get_latency", true);
const rtt = new Trend("rtt", true);
const setupTotal = new Trend("setup_total", true);
const suback = new Trend("suback", true);
const writesIssued = new Counter("writes_issued");
const refreshesObserved = new Counter("refreshes_observed");
const refreshGets = new Counter("refresh_gets");
const steadyStateSetupLeaks = new Counter("steady_state_setup_leaks");

const N_VUS = parseInt(__ENV.BENCH_VUS || "50", 10);
const STEADY_SECONDS = parseInt(__ENV.IDENTITY_FREE_FEED_STEADY_S || "20", 10);
const N_WRITERS = parseInt(__ENV.IDENTITY_FREE_FEED_WRITERS || "1", 10);
const SETUP_WINDOW_SECONDS = Math.ceil(warmSetupWindowMs() / 1000);

export const options = {
  summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
  thresholds: {
    checks: ["rate==1"],
    steady_state_setup_leaks: ["count==0"],
    writes_issued: [`count>=${N_WRITERS}`],
    refreshes_observed: [`count>=${Math.max(1, N_VUS - N_WRITERS)}`],
    refresh_gets: [`count>=${Math.max(1, N_VUS - N_WRITERS)}`],
  },
  scenarios: {
    identity_free_feed_turbo: {
      executor: "per-vu-iterations",
      vus: N_VUS,
      iterations: 1,
      maxDuration: `${SETUP_WINDOW_SECONDS + STEADY_SECONDS + 60}s`,
    },
  },
};

function receiveApplicationMessage(sub, timeoutSeconds) {
  const deadline = Date.now() + timeoutSeconds * 1000;

  while (Date.now() < deadline) {
    const message = sub.receive();
    if (!message) {
      sleep(0.05);
      continue;
    }
    if (isApplicationMessage(message)) return message;
  }

  return null;
}

function sentAtFromText(text) {
  const match = `${text || ""}`.match(/feed \d+-(\d{10,})/);
  return match ? parseInt(match[1], 10) : null;
}

function consumeApplicationMessages(sub, timeoutSeconds, expectedMessages, onMessage) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  let received = 0;

  while (received < expectedMessages && Date.now() < deadline) {
    const remainingSeconds = Math.max(0, (deadline - Date.now()) / 1000);
    const message = receiveApplicationMessage(sub, remainingSeconds);
    if (!message) return;
    onMessage(message);
    received += 1;
  }
}

function fetchRefresh() {
  const startedAt = Date.now();
  const res = http.get(`${BASE_URL}/feed`, {
    tags: { name: "GET_feed_refresh" },
  });
  refreshGetLatency.add(Date.now() - startedAt);
  refreshGets.add(1);
  check(res, { "refresh get 200": (r) => r.status === 200 });
  return res.body;
}

function recordRefresh() {
  refreshesObserved.add(1);
  const body = fetchRefresh();
  const sentAt = sentAtFromText(body);
  if (sentAt) rtt.add(Date.now() - sentAt);
}

export default function () {
  const scenarioStartAt = new Date(exec.scenario.startTime).getTime();
  const measuredPhaseStartsAt = scenarioStartAt + warmSetupWindowMs();
  const admission = warmSetupAdmissionForVu(__VU);
  if (admission.delayMs > 0) sleep(admission.delayMs / 1000);

  const setupStartedAt = Date.now();

  const pageStartedAt = Date.now();
  const pageRes = http.get(`${BASE_URL}/feed`);
  pageRender.add(Date.now() - pageStartedAt);
  check(pageRes, { "feed loaded": (r) => r.status === 200 });

  const token = pageRes.body ? findBetween(pageRes.body, 'signed-stream-name="', '"') : "";
  if (!token) fail("could not extract signed-stream-name from /feed");

  const client = cable.connect(WS_URL, {
    receiveTimeoutMs: 5000,
  });
  if (!check(client, { connected: (c) => c })) fail("WS connect failed");

  const sub = client.subscribe("Turbo::StreamsChannel", { signed_stream_name: token });
  if (!check(sub, { subscribed: (ch) => ch })) fail("subscribe failed");
  suback.add(sub.ackDuration());
  const setupCompletedAt = Date.now();
  setupTotal.add(setupCompletedAt - setupStartedAt);

  if (setupCompletedAt > measuredPhaseStartsAt) steadyStateSetupLeaks.add(1);

  const waitSeconds = Math.max(0, measuredPhaseStartsAt - Date.now()) / 1000;
  if (waitSeconds > 0) sleep(waitSeconds);

  if (__VU <= N_WRITERS) {
    const offsetMs = N_WRITERS > 1 ? ((__VU - 1) * 1000) / N_WRITERS : 0;
    if (offsetMs > 0) sleep(offsetMs / 1000);

    const sendTs = Date.now();
    const nonce = `${__VU}-${sendTs}`;
    const res = http.post(
      `${BASE_URL}/feed`,
      { title: `feed ${nonce}`, body: `identity-free body ${nonce}` },
      { tags: { name: "POST_feed" } }
    );
    postLatency.add(res.timings.duration);
    check(res, { "feed post 2xx": (r) => r.status >= 200 && r.status < 300 });
    writesIssued.add(1);
  }

  consumeApplicationMessages(sub, STEADY_SECONDS, N_WRITERS, () => recordRefresh());

  client.disconnect();
}

export function handleSummary(data) {
  const targetPath = __ENV.K6_SUMMARY_PATH || "results/render-dedup-identity-free-feed-turbo.json";
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    [targetPath]: JSON.stringify(data),
  };
}
