// G7 high-sharing benchmark scenario.
//
// N VUs (default 50) all subscribe to the exact same identity-free page
// (`/feed`). One designated writer (the lowest-numbered VU) issues a
// single POST mid-scenario; every other VU waits on the resulting
// DeliveryEnvelope.
//
// The single PATCH triggers one render group (dedup-coalesced across
// the N subscribers) and N DeliveryEnvelopes.
// The Ruby post-processing step in benchmark/bin/run samples the dispatch
// /metrics endpoint before and after the scenario and computes the
// headline ratio `deliveries / render_groups` (>=5 satisfies G7).

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
const STEADY_SECONDS = parseInt(__ENV.HIGH_SHARING_STEADY_S || "15");

export const options = {
  summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
  scenarios: {
    shared_identity_free: {
      executor: "per-vu-iterations",
      vus: N_VUS,
      iterations: 1,
      maxDuration: `${STEADY_SECONDS + 30}s`,
    },
  },
};

export default function () {
  const userIdx = ((__VU - 1) % NUM_USERS) + 1;
  const email = `user${userIdx}@bench.test`;
  const jar = login(BASE_URL, email, "benchpass123");

  const pageRes = http.get(`${BASE_URL}/feed`, { jar });
  check(pageRes, { "page loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!token) fail("could not extract context_token");

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

    if (__VU === 1) {
      sock.setTimeout(function () {
        sendTs = Date.now();
        const res = http.post(
          `${BASE_URL}/feed`,
          { title: `shared ${__VU}`, body: `feed item ${__VU}` },
          { jar, tags: { name: "POST_feed" } }
        );
        check(res, { "post 201": (r) => r.status === 201 });
        writesIssued.add(1);
      }, 3000);
    }

    sock.setTimeout(function () { sock.close(); }, STEADY_SECONDS * 1000);
  });

  check(wsResult, { "ws connected": (r) => r && r.status === 101 });
}

export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    "results/render-dedup-shared-identity-free.json": JSON.stringify(data),
  };
}
