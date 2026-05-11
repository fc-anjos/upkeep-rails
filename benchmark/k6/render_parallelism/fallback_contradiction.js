// fallback_contradiction — measures the per-sid runtime-contradiction
// fallback fan-out. N authenticated VUs subscribe to /signed_feed,
// whose `_feed_item_signed.html.erb` partial calls a helper that
// reads `Current.user` at render time. The compile-time classifier
// tags the partial `:none`; runtime identity observation logs the
// access; the atomic delivery gate raises ClassificationDowngraded on
// every invalidation; the dispatcher re-renders once per sid with
// `force_unknown_tier: true`.
//
// Comparing this workload at UPKEEP_RENDER_CONCURRENCY=1 vs =10
// measures whether parallelizing the fallback fan-out (Task 6 of the
// render-parallelism plan) reduces the worst-case fallback p95.
//
// Expected relay shape (deltas across the run):
//   - classification_downgrades_total > 0 (by design)
//   - per_sid_fallback_duration_seconds samples present
//   - one delivery per VU per write
//   - render_call_errors_total delta == 0

import http from "k6/http";
import ws from "k6/ws";
import { check, fail } from "k6";
import { Counter, Trend } from "k6/metrics";
import { BASE_URL, WS_URL, NUM_USERS } from "../utils/config.js";
import { login } from "../utils/auth.js";
import { findBetween } from "../utils/index.js";
import { textSummary } from "../utils/summary.js";
import { relayWsUrl } from "../utils/relay_scenario.js";

const rtt = new Trend("rtt", true);
const writesIssued = new Counter("writes_issued");
const deliveries = new Counter("deliveries_observed");

const N_VUS = parseInt(__ENV.BENCH_VUS || "50");
const WRITER_EVERY = parseInt(__ENV.SHARED_FEED_WRITER_EVERY || `${Math.max(1, N_VUS)}`);
const WRITES_PER_WRITER = parseInt(__ENV.SHARED_FEED_WRITES || "5");
const STEADY_SECONDS = parseInt(__ENV.SHARED_FEED_STEADY_S || "20");
const WRITER_COUNT = Math.max(1, Math.floor(N_VUS / WRITER_EVERY));
const EXPECTED_WRITES = WRITER_COUNT * WRITES_PER_WRITER;
const EXPECTED_DELIVERIES = N_VUS * EXPECTED_WRITES;

export const options = {
  summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
  thresholds: {
    checks: ["rate==1"],
    writes_issued: [`count>=${EXPECTED_WRITES}`],
    deliveries_observed: [`count>=${EXPECTED_DELIVERIES}`],
  },
  scenarios: {
    fallback_contradiction: {
      executor: "per-vu-iterations",
      vus: N_VUS,
      iterations: 1,
      maxDuration: `${STEADY_SECONDS + 30}s`,
    },
  },
};

export default function () {
  const email = `user${(__VU % NUM_USERS) + 1}@bench.test`;
  const jar = login(BASE_URL, email, "benchpass123");

  const pageRes = http.get(`${BASE_URL}/signed_feed`, { jar });
  check(pageRes, { "signed_feed loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!token) fail("could not extract context_token from /signed_feed");

  const isWriter = __VU % WRITER_EVERY === 0;

  const wsResult = ws.connect(relayWsUrl(WS_URL, token), {}, function (sock) {
    let sendTs = null;

    sock.on("binaryMessage", function () {
      deliveries.add(1);
      if (sendTs !== null) {
        rtt.add(Date.now() - sendTs);
        sendTs = null;
      }
    });
    sock.setInterval(function () {}, 1000);

    if (isWriter) {
      let i = 0;
      const fire = function () {
        if (i >= WRITES_PER_WRITER) return;
        const writeIndex = i++;
        sendTs = Date.now();
        const res = http.post(`${BASE_URL}/signed_feed`, {
          title: `signed feed ${__VU}-${writeIndex}`,
          body: `signed feed body ${__VU}-${writeIndex}`,
        }, { jar });
        check(res, { "signed_feed post 2xx": (r) => r.status >= 200 && r.status < 300 });
        writesIssued.add(1);
        sock.setTimeout(fire, 1000);
      };
      sock.setTimeout(fire, 3000);
    }

    sock.setTimeout(function () { sock.close(); }, STEADY_SECONDS * 1000);
  });

  check(wsResult, { "ws connected": (r) => r && r.status === 101 });
}

export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    "results/render-parallelism-fallback-contradiction.json": JSON.stringify(data),
  };
}
