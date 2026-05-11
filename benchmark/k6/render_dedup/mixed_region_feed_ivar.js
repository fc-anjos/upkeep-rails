// Ivar-shaped mixed-region render-dedup scenario.
//
// N authenticated VUs subscribe to the singular FeaturedItems resource.
// The page renders a fragment whose dynamic sources are controller
// ivars (`@featured_item.title`, `@featured_item.body`). At subscribe
// time, `SlotStateCapture` resolves each ivar via `view_assigns`
// threaded through `FragmentRegistrationMetadata::Builder`, populating
// `fragment_slot_states["value"]` for the ivar-bound slots. One writer
// updates the featured item; every subscriber should receive a
// byte-equality-proven patch (no synthetic-request render) because the
// proof gate now sees a populated binding.
//
// This workload is the F3 follow-up that exercises the new ivar code
// path. The sibling `mixed_region_feed.js` workload uses local-receiver
// templates that were already covered before the
// `direct-push-proof-expansion` candidate; this workload is the
// counterpart that drives the new view-assigns-derived bindings.

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
const STEADY_SECONDS = parseInt(__ENV.IVAR_FEED_STEADY_S || "20", 10);
const N_WRITERS = parseInt(__ENV.FEATURED_WRITERS || "1", 10);

export const options = {
  summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
  thresholds: {
    checks: ["rate==1"],
    writes_issued: [`count>=${N_WRITERS}`],
    deliveries_observed: [`count>=${N_VUS - N_WRITERS}`],
  },
  scenarios: {
    mixed_region_feed_ivar: {
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

  const pageRes = http.get(`${BASE_URL}/featured_item`, { jar });
  check(pageRes, { "featured_item loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!token) fail("could not extract context_token from /featured_item");

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

    if (__VU <= N_WRITERS) {
      const offsetMs = N_WRITERS > 1 ? ((__VU - 1) * 1000) / N_WRITERS : 0;
      sock.setTimeout(function () {
        sendTs = Date.now();
        const nonce = `${__VU}-${sendTs}`;
        const res = http.patch(
          `${BASE_URL}/featured_item`,
          { title: `Featured title ${nonce}`, body: `Featured body ${nonce}` },
          { jar, tags: { name: "PATCH_featured_item" } }
        );
        check(res, { "featured update 2xx": (r) => r.status >= 200 && r.status < 300 });
        writesIssued.add(1);
      }, 3000 + offsetMs);
    }

    sock.setTimeout(function () { sock.close(); }, STEADY_SECONDS * 1000);
  });

  check(wsResult, { "ws connected": (r) => r && r.status === 101 });
}

export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    "results/render-dedup-mixed-region-feed-ivar.json": JSON.stringify(data),
  };
}
