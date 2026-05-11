// Shared-feed memory ceiling workload for Turbo.
//
// All VUs subscribe to a shared Turbo refresh stream. VU 1 issues the
// write burst. Each received refresh event triggers the same GET `/feed`
// a browser would perform after a Turbo page refresh.

import http from "k6/http";
import exec from "k6/execution";
import { check, fail, sleep } from "k6";
import cable from "k6/x/cable";
import { Counter, Trend } from "k6/metrics";
import {
  BASE_URL,
  WS_URL,
  NUM_USERS,
  warmSetupAdmissionForVu,
  warmSetupWindowMs,
} from "../utils/config.js";
import { login, cookieString } from "../utils/auth.js";
import { findBetween } from "../utils/index.js";
import { isApplicationMessage } from "../utils/messages.js";
import { textSummary } from "../utils/summary.js";

const postLatency = new Trend("post_latency", true);
const refreshGetLatency = new Trend("refresh_get_latency", true);
const suback = new Trend("suback", true);
const writesIssued = new Counter("writes_issued");
const refreshesObserved = new Counter("refreshes_observed");
const refreshGets = new Counter("refresh_gets");

const N_VUS = parseInt(__ENV.BENCH_VUS || "50", 10);
const WRITES = parseInt(__ENV.WRITES_PER_VU || "3", 10);
const SETTLE_SECONDS = parseInt(__ENV.MEMORY_STEADY_SECONDS || "5", 10);
const WRITE_INTERVAL_MS = parseInt(__ENV.MEMORY_WRITE_INTERVAL_MS || "250", 10);
// See the upkeep variant for rationale; mirrored here so the two
// workloads write the same shape and remain apples-to-apples.
const WRITES_TO_SUBSCRIBED_ROWS_FRACTION = parseFloat(
  __ENV.WRITES_TO_SUBSCRIBED_ROWS_FRACTION || "0.5"
);
const SETUP_WINDOW_SECONDS = Math.ceil(warmSetupWindowMs() / 1000);
const WRITE_BURST_SECONDS = Math.ceil((WRITES * WRITE_INTERVAL_MS) / 1000);
const DRAIN_SECONDS = SETTLE_SECONDS + WRITE_BURST_SECONDS + 20;

export const options = {
  summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
  scenarios: {
    shared_feed_churn_turbo: {
      executor: "per-vu-iterations",
      vus: N_VUS,
      iterations: 1,
      maxDuration: `${SETUP_WINDOW_SECONDS + DRAIN_SECONDS + 60}s`,
    },
  },
  thresholds: {
    writes_issued: [`count==${WRITES}`],
    refreshes_observed: ["count>0"],
    refresh_gets: ["count>0"],
  },
};

function receiveApplicationMessages(sub, timeoutSeconds = 0) {
  return sub.receiveAll(timeoutSeconds).filter((message) => {
    return isApplicationMessage(message, "Turbo::StreamsChannel");
  });
}

function fetchRefresh(baseUrl, jar) {
  const startedAt = Date.now();
  const res = http.get(`${baseUrl}/feed`, {
    jar,
    tags: { name: "GET_feed_refresh" },
  });
  refreshGetLatency.add(Date.now() - startedAt);
  refreshGets.add(1);
  check(res, { "refresh get 200": (r) => r.status === 200 });
}

export default function () {
  const scenarioStartAt = new Date(exec.scenario.startTime).getTime();
  const writePhaseStartsAt = scenarioStartAt + warmSetupWindowMs();
  const admission = warmSetupAdmissionForVu(__VU);
  if (admission.delayMs > 0) sleep(admission.delayMs / 1000);

  const userIdx = ((__VU - 1) % NUM_USERS) + 1;
  const jar = login(BASE_URL, `user${userIdx}@bench.test`, "benchpass123");

  const pageRes = http.get(`${BASE_URL}/feed`, { jar });
  check(pageRes, { "page loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, 'signed-stream-name="', '"');
  if (!token) fail("could not extract signed-stream-name");

  const subscribedRowId =
    parseInt(findBetween(pageRes.body, 'id="feed_item_', '"') || "1", 10);

  const client = cable.connect(WS_URL, {
    receiveTimeoutMs: 30000,
    cookies: cookieString(jar, BASE_URL),
  });
  if (!check(client, { connected: (c) => c })) fail("WS connect failed");

  const sub = client.subscribe("Turbo::StreamsChannel", { signed_stream_name: token });
  if (!check(sub, { subscribed: (ch) => ch })) fail("subscribe failed");
  suback.add(sub.ackDuration());

  const waitSeconds = Math.max(0, writePhaseStartsAt - Date.now()) / 1000;
  if (waitSeconds > 0) sleep(waitSeconds);
  sleep(SETTLE_SECONDS);

  if (__VU === 1) {
    for (let i = 0; i < WRITES; i += 1) {
      const targetSubscribedRow =
        WRITES_TO_SUBSCRIBED_ROWS_FRACTION > 0 &&
        Math.random() < WRITES_TO_SUBSCRIBED_ROWS_FRACTION;
      const res = targetSubscribedRow
        ? http.patch(
            `${BASE_URL}/feed_items/${subscribedRowId}`,
            { title: `memory upd ${i}`, body: `shared feed churn upd ${i}` },
            { jar, tags: { name: "PATCH_feed_item" } }
          )
        : http.post(
            `${BASE_URL}/feed`,
            { title: `memory ${i}`, body: `shared feed churn ${i}` },
            { jar, tags: { name: "POST_feed" } }
          );
      postLatency.add(res.timings.duration);
      check(res, {
        "post 2xx": (r) => r.status >= 200 && r.status < 300,
      });
      writesIssued.add(1);

      for (const message of receiveApplicationMessages(sub, 1)) {
        refreshesObserved.add(1);
        fetchRefresh(BASE_URL, jar);
      }
      sleep(WRITE_INTERVAL_MS / 1000);
    }
  } else {
    for (const message of receiveApplicationMessages(sub, DRAIN_SECONDS)) {
      refreshesObserved.add(1);
      fetchRefresh(BASE_URL, jar);
    }
  }

  client.disconnect();
}

export function handleSummary(data) {
  const targetPath = __ENV.K6_SUMMARY_PATH || "results/memory-ceiling-shared-feed-churn-turbo.json";
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    [targetPath]: JSON.stringify(data),
  };
}
