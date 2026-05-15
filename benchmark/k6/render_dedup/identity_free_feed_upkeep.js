// Identity-free shared feed comparison workload for Upkeep.
//
// The `/feed` page and write endpoint are anonymous-capable and skip
// Current.user. Upkeep should classify the captured graph as public,
// register an anonymous-public subscription, and allow the socket to
// subscribe without a login/session.

import http from "k6/http";
import { check, fail, sleep } from "k6";
import cable from "k6/x/cable";
import exec from "k6/execution";
import { Counter, Trend } from "k6/metrics";
import { BASE_URL, warmSetupAdmissionForVu, warmSetupWindowMs } from "../utils/config.js";
import { findBetween } from "../utils/index.js";
import { isApplicationMessage, serializeCableApplicationMessage } from "../utils/messages.js";
import { textSummary } from "../utils/summary.js";

const pageRender = new Trend("page_render", true);
const postLatency = new Trend("post_latency", true);
const rtt = new Trend("rtt", true);
const setupTotal = new Trend("setup_total", true);
const suback = new Trend("suback", true);
const writesIssued = new Counter("writes_issued");
const deliveries = new Counter("deliveries_observed");
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
    deliveries_observed: [`count>=${Math.max(1, N_VUS - N_WRITERS)}`],
  },
  scenarios: {
    identity_free_feed_upkeep: {
      executor: "per-vu-iterations",
      vus: N_VUS,
      iterations: 1,
      maxDuration: `${SETUP_WINDOW_SECONDS + STEADY_SECONDS + 60}s`,
    },
  },
};

function subscriptionIdFrom(body) {
  if (!body) return "";

  const marker = findBetween(body, "data-upkeep-subscription>", "</script>");
  if (!marker) return "";

  try {
    return JSON.parse(marker).subscription_id || "";
  } catch {
    return "";
  }
}

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

function recordDelivery(message) {
  deliveries.add(1);
  const sentAt = sentAtFromText(serializeCableApplicationMessage(message));
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

  const subscriptionId = subscriptionIdFrom(pageRes.body);
  if (!subscriptionId) fail("could not extract data-upkeep-subscription from /feed");

  const client = cable.connect(`${BASE_URL.replace(/^http/, "ws")}/cable`, {
    receiveTimeoutMs: 5000,
  });
  if (!check(client, { connected: (c) => c })) fail("WS connect failed");

  const sub = client.subscribe("Upkeep::Rails::Cable::Channel", { subscription_id: subscriptionId });
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

  consumeApplicationMessages(sub, STEADY_SECONDS, N_WRITERS, recordDelivery);

  client.disconnect();
}

export function handleSummary(data) {
  const targetPath = __ENV.K6_SUMMARY_PATH || "results/render-dedup-identity-free-feed-upkeep.json";
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    [targetPath]: JSON.stringify(data),
  };
}
