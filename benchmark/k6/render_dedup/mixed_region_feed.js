// Mixed-region render-dedup scenario.
//
// N authenticated VUs subscribe to /mixed_feed. The page renders shared
// FeedItem title/body output beside Current-dependent and transient
// Current-derived output inside the same outer fragment. One writer
// updates the shared FeedItem row; every subscriber waits for the
// resulting delivery.

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

const N_VUS = parseInt(__ENV.BENCH_VUS || "50", 10);
const ITEM_ID = parseInt(__ENV.MIXED_FEED_ITEM_ID || "1", 10);
const STEADY_SECONDS = parseInt(__ENV.MIXED_FEED_STEADY_S || "20", 10);

export const options = {
  summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
  thresholds: {
    checks: ["rate==1"],
    writes_issued: ["count>=1"],
    deliveries_observed: [`count>=${N_VUS}`],
  },
  scenarios: {
    mixed_region_feed: {
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

  const pageRes = http.get(`${BASE_URL}/mixed_feed`, { jar });
  check(pageRes, { "mixed_feed loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!token) fail("could not extract context_token from /mixed_feed");

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
        const nonce = `${__VU}-${sendTs}`;
        const res = http.post(
          `${BASE_URL}/mixed_feed/${ITEM_ID}`,
          { title: `Mixed title ${nonce}`, body: `Mixed body ${nonce}` },
          { jar, tags: { name: "POST_mixed_feed_item" } }
        );
        check(res, { "mixed update 2xx": (r) => r.status >= 200 && r.status < 300 });
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
    "results/render-dedup-mixed-region-feed.json": JSON.stringify(data),
  };
}
