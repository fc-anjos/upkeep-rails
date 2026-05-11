// identity_free_feed benchmark scenario — classifier and request-free
// route validation for a `:none`-tier surface.
//
// N anonymous VUs all subscribe to the same `/feed` page. A small
// number of writer VUs POST new feed items; every other VU receives
// the resulting DeliveryEnvelope. Because `_feed_item.html.erb` is
// structurally identity-free (the classifier resolves it to `:none`),
// dispatch should collapse the fan-out to one render per item
// regardless of subscriber count. The expected dispatch shape is:
//
//   - render_groups_by_tier{tier="none"} ≈ writes issued
//   - render_groups_by_tier{tier="user-keyed"} ≈ 0
//   - render_dedup_savings_total ≈ writes × (N - 1)
//   - dedup_ratio → 1.0 as N grows
//   - classification_downgrades_total == 0
//
// Anonymous by design: the `/feed` route skips login and CSRF, so the
// page fetch + write path carry no identity state. This is the inverse
// of the chat scenarios, where each VU authenticates and `Current.user`
// reads force the per-subscriber render.

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

export const options = {
  summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
  scenarios: {
    identity_free_feed: {
      executor: "per-vu-iterations",
      vus: N_VUS,
      iterations: 1,
      maxDuration: `${STEADY_SECONDS + 30}s`,
    },
  },
};

export default function () {
  // Relay handshake requires a verified token even though /feed itself
  // is anonymous-capable — every VU logs in first so the page render
  // issues a context token. The feed view and partial still read no
  // identity tokens, so the classifier resolves the render path
  // to `:none` regardless of whether a user is signed in.
  const email = `user${(__VU % NUM_USERS) + 1}@bench.test`;
  const jar = login(BASE_URL, email, "benchpass123");

  const pageRes = http.get(`${BASE_URL}/feed`, { jar });
  check(pageRes, { "feed loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!token) fail("could not extract context_token from /feed");

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
        const res = http.post(`${BASE_URL}/feed`, {
          title: `feed ${__VU}-${writeIndex}`,
          body: `shared feed body ${__VU}-${writeIndex}`,
        }, { jar });
        check(res, { "feed post 2xx": (r) => r.status >= 200 && r.status < 300 });
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
    "results/classifier-identity-free-feed.json": JSON.stringify(data),
  };
}
