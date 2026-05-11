// Turbo mirror of the ivar-shaped render-dedup scenario.
//
// N authenticated VUs subscribe to the singular FeaturedItems
// resource. The page mounts `<%= turbo_stream_from "feed_items" %>`
// and renders the same `_featured_item` partial as the upkeep
// variant. One writer updates the featured item; the model's
// `after_update_commit` callback broadcasts a refresh to every
// subscriber, which then re-fetches the page (the standard Turbo
// refresh shape).
//
// Pair this with the upkeep-side `mixed_region_feed_ivar.js`. The
// route runner reports both side-by-side so the bytes-on-wire and
// RSS gap between Turbo's full-refresh delivery and Upkeep's
// proof-gate compact-ops delivery is visible in one comparison.

import http from "k6/http";
import { check, fail, sleep } from "k6";
import cable from "k6/x/cable";
import { Counter, Trend } from "k6/metrics";
import { BASE_URL, WS_URL, NUM_USERS } from "../utils/config.js";
import { login, cookieString } from "../utils/auth.js";
import { findBetween } from "../utils/index.js";
import { isApplicationMessage } from "../utils/messages.js";
import { textSummary } from "../utils/summary.js";

const rtt = new Trend("rtt", true);
const refreshGetLatency = new Trend("refresh_get_latency", true);
const suback = new Trend("suback", true);
const writesIssued = new Counter("writes_issued");
const refreshesObserved = new Counter("refreshes_observed");
const refreshGets = new Counter("refresh_gets");

const N_VUS = parseInt(__ENV.BENCH_VUS || "50", 10);
const STEADY_SECONDS = parseInt(__ENV.IVAR_FEED_STEADY_S || "20", 10);
// See the upkeep variant; mirrored here so both apps see the same
// writer/subscriber split.
const N_WRITERS = parseInt(__ENV.FEATURED_WRITERS || "1", 10);

export const options = {
  summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
  thresholds: {
    checks: ["rate==1"],
    writes_issued: [`count>=${N_WRITERS}`],
    refreshes_observed: [`count>=${N_VUS - N_WRITERS}`],
  },
  scenarios: {
    mixed_region_feed_ivar_turbo: {
      executor: "per-vu-iterations",
      vus: N_VUS,
      iterations: 1,
      maxDuration: `${STEADY_SECONDS + 30}s`,
    },
  },
};

function fetchRefresh(jar) {
  const startedAt = Date.now();
  const res = http.get(`${BASE_URL}/featured_item`, {
    jar,
    tags: { name: "GET_featured_item_refresh" },
  });
  refreshGetLatency.add(Date.now() - startedAt);
  refreshGets.add(1);
  check(res, { "refresh get 200": (r) => r.status === 200 });
}

function receiveApplicationMessages(sub, timeoutSeconds = 0) {
  return sub.receiveAll(timeoutSeconds).filter((message) => {
    return isApplicationMessage(message, "Turbo::StreamsChannel");
  });
}

export default function () {
  const userIdx = ((__VU - 1) % NUM_USERS) + 1;
  const email = `user${userIdx}@bench.test`;
  const jar = login(BASE_URL, email, "benchpass123");

  const pageRes = http.get(`${BASE_URL}/featured_item`, { jar });
  check(pageRes, { "featured_item loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, 'signed-stream-name="', '"');
  if (!token) fail("could not extract signed-stream-name from /featured_item");

  const client = cable.connect(WS_URL, {
    receiveTimeoutMs: 30000,
    cookies: cookieString(jar, BASE_URL),
  });
  if (!check(client, { connected: (c) => c })) fail("WS connect failed");

  const sub = client.subscribe("Turbo::StreamsChannel", { signed_stream_name: token });
  if (!check(sub, { subscribed: (ch) => ch })) fail("subscribe failed");
  suback.add(sub.ackDuration());

  sleep(3);

  if (__VU <= N_WRITERS) {
    const offsetMs = N_WRITERS > 1 ? ((__VU - 1) * 1000) / N_WRITERS : 0;
    if (offsetMs > 0) sleep(offsetMs / 1000);

    const sendTs = Date.now();
    const nonce = `${__VU}-${sendTs}`;
    const res = http.patch(
      `${BASE_URL}/featured_item`,
      { title: `Featured title ${nonce}`, body: `Featured body ${nonce}` },
      { jar, tags: { name: "PATCH_featured_item" } }
    );
    check(res, { "featured update 2xx": (r) => r.status >= 200 && r.status < 300 });
    writesIssued.add(1);

    let first = true;
    for (const _message of receiveApplicationMessages(sub, STEADY_SECONDS)) {
      refreshesObserved.add(1);
      fetchRefresh(jar);
      if (first) {
        rtt.add(Date.now() - sendTs);
        first = false;
      }
    }
  } else {
    for (const _message of receiveApplicationMessages(sub, STEADY_SECONDS)) {
      refreshesObserved.add(1);
      fetchRefresh(jar);
    }
  }

  client.disconnect();
}

export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    "results/render-dedup-mixed-region-feed-ivar-turbo.json": JSON.stringify(data),
  };
}
