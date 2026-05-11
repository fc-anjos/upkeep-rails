// Shared-feed memory ceiling workload.
//
// Clients connect to the benchmark WebSocket endpoint using the signed
// `data-context-token` the page render embeds. The HTTP page render goes
// through Rails; the long-lived WebSocket carries delivery frames.
//
// Frame counting is bytes-only: dispatch sends binary msgpack
// envelopes; this workload counts every received frame as a delivery
// rather than parsing the payload. That is sufficient to validate the
// memory floor and the per-connection cost on the dispatch side.

import http from "k6/http";
import exec from "k6/execution";
import ws from "k6/ws";
import { check, fail, sleep } from "k6";
import { Counter, Trend } from "k6/metrics";
import {
  BASE_URL,
  RELAY_WS_URL,
  NUM_USERS,
  warmSetupAdmissionForVu,
  warmSetupWindowMs,
} from "../utils/config.js";
import { login, cookieString } from "../utils/auth.js";
import { findBetween } from "../utils/index.js";
import { textSummary } from "../utils/summary.js";

const postLatency = new Trend("post_latency", true);
const rtt = new Trend("rtt", true);
const writesIssued = new Counter("writes_issued");
const deliveries = new Counter("deliveries_observed");

const N_VUS = parseInt(__ENV.BENCH_VUS || "50", 10);
const WRITES = parseInt(__ENV.WRITES_PER_VU || "3", 10);
const SETTLE_SECONDS = parseInt(__ENV.MEMORY_STEADY_SECONDS || "5", 10);
const WRITE_INTERVAL_MS = parseInt(__ENV.MEMORY_WRITE_INTERVAL_MS || "250", 10);
const WRITES_TO_SUBSCRIBED_ROWS_FRACTION = parseFloat(
  __ENV.WRITES_TO_SUBSCRIBED_ROWS_FRACTION || "0.5"
);
const SETUP_WINDOW_SECONDS = Math.ceil(warmSetupWindowMs() / 1000);
const WRITE_BURST_SECONDS = Math.ceil((WRITES * WRITE_INTERVAL_MS) / 1000);
const DRAIN_SECONDS = SETTLE_SECONDS + WRITE_BURST_SECONDS + 20;

function markMemoryPhase(jar, phase) {
  http.get(`${BASE_URL}/bench/metrics?memory_phase=${phase}`, {
    jar,
    tags: { name: "GET_bench_metrics" },
  });
}

export const options = {
  scenarios: {
    shared_feed_churn_upkeep: {
      executor: "per-vu-iterations",
      vus: N_VUS,
      iterations: 1,
      maxDuration: `${SETUP_WINDOW_SECONDS + DRAIN_SECONDS + 60}s`,
    },
  },
  thresholds: {
    writes_issued: [`count==${WRITES}`],
    deliveries_observed: ["count>0"],
  },
};

export default function () {
  const scenarioStartAt = new Date(exec.scenario.startTime).getTime();
  const writePhaseStartsAt = scenarioStartAt + warmSetupWindowMs();
  const admission = warmSetupAdmissionForVu(__VU);
  if (admission.delayMs > 0) sleep(admission.delayMs / 1000);

  const userIdx = ((__VU - 1) % NUM_USERS) + 1;
  const jar = login(BASE_URL, `user${userIdx}@bench.test`, "benchpass123");

  const pageRes = http.get(`${BASE_URL}/feed`, { jar });
  check(pageRes, { "page loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!token) fail("could not extract context_token");

  const subscribedRowId =
    parseInt(findBetween(pageRes.body, 'id="feed_item_', '"') || "1", 10);

  const wsUrl = `${RELAY_WS_URL}/?token=${encodeURIComponent(token)}`;
  let socket = null;
  let lastSendTs = null;

  const wsResult = ws.connect(wsUrl, {}, function (sock) {
    socket = sock;
    const connectedAt = Date.now();

    sock.on("open", function () {
      console.log(`VU=${__VU} ws open after ${Date.now() - connectedAt}ms`);
    });

    sock.on("binaryMessage", function (_data) {
      deliveries.add(1);
      if (lastSendTs !== null) {
        rtt.add(Date.now() - lastSendTs);
        lastSendTs = null;
      }
    });

    sock.on("close", function (code) {
      console.log(`VU=${__VU} ws close code=${code} after ${Date.now() - connectedAt}ms`);
    });

    sock.on("error", function (err) {
      console.log(`VU=${__VU} ws error: ${err}`);
    });

    // Keep-alive interval: k6/ws's `ws.connect` blocks until the
    // socket closes, but only fires scheduled timers/intervals while
    // there is at least one timer registered. A periodic no-op keeps
    // the timer wheel alive so subsequent setTimeouts fire as
    // scheduled.
    sock.setInterval(function () {}, 1_000);

    if (__VU === 1) {
      const writePhaseDelay = Math.max(0, writePhaseStartsAt - Date.now()) + SETTLE_SECONDS * 1000;

      sock.setTimeout(function () { markMemoryPhase(jar, "after_subscribe"); }, Math.max(50, writePhaseStartsAt - Date.now()));

      for (let i = 0; i < WRITES; i += 1) {
        const fireAt = writePhaseDelay + i * WRITE_INTERVAL_MS;
        sock.setTimeout(function () {
          lastSendTs = Date.now();
          const targetSubscribedRow =
            WRITES_TO_SUBSCRIBED_ROWS_FRACTION > 0 &&
            Math.random() < WRITES_TO_SUBSCRIBED_ROWS_FRACTION;
          const res = targetSubscribedRow
            ? http.patch(
                `${BASE_URL}/feed_items/${subscribedRowId}`,
                { title: `memory upd ${i}`, body: `churn upd ${i}` },
                { jar, tags: { name: "PATCH_feed_item" } }
              )
            : http.post(
                `${BASE_URL}/feed`,
                { title: `memory ${i}`, body: `churn ${i}` },
                { jar, tags: { name: "POST_feed" } }
              );
          postLatency.add(res.timings.duration);
          check(res, { "post 2xx": (r) => r.status >= 200 && r.status < 300 });
          writesIssued.add(1);
        }, fireAt);
      }

      sock.setTimeout(function () { markMemoryPhase(jar, "after_writes"); }, writePhaseDelay + WRITE_BURST_SECONDS * 1000);
      sock.setTimeout(function () { markMemoryPhase(jar, "after_drain"); }, writePhaseDelay + WRITE_BURST_SECONDS * 1000 + 5_000);
    }

    sock.setTimeout(function () { sock.close(); }, (SETUP_WINDOW_SECONDS + DRAIN_SECONDS) * 1000);
  });

  check(wsResult, { "ws connected": (r) => r && r.status === 101 });
}

export function handleSummary(data) {
  const targetPath = __ENV.K6_SUMMARY_PATH || "results/memory-ceiling-shared-feed-churn-upkeep.json";
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    [targetPath]: JSON.stringify(data),
  };
}
