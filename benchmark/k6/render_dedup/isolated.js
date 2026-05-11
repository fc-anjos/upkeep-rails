// Isolated render-dedup scenario — explicit inverse of
// shared_identity_free.
//
// N VUs each subscribe to their OWN board page (`/boards/{boardId}`),
// where boardId is allocated per-VU from the per-user solo boards
// seeded by `BenchmarkSeed#create_per_user_boards` when
// `LOW_SHARING_BOARDS` is set. Then every VU is also a writer, issuing
// one PATCH against one of their own cards.
//
// Expected relay shape (regression-guard direction):
//   - render_groups_total ≈ N
//   - render_dedup_savings_total ≈ 0
//   - dedup_ratio ≈ 0.0  (subs_served = N, savings = 0)
//   - deliveries / render_requests ≈ 1.0
//
// This is the antagonist of shared_identity_free: upkeep carries the
// ReadSet match + IPC overhead with no dedup payoff. The bench exists
// so a regression that fakes high dedup ratios — or breaks per-sub
// isolation — fails this scenario loudly even if shared_identity_free still
// looks healthy.

import http from "k6/http";
import ws from "k6/ws";
import { check, fail } from "k6";
import { Counter, Trend } from "k6/metrics";
import { BASE_URL, WS_URL, NUM_USERS } from "../utils/config.js";
import { login, extractCsrfToken } from "../utils/auth.js";
import { findBetween } from "../utils/index.js";
import { textSummary } from "../utils/summary.js";
import { relayWsUrl } from "../utils/relay_scenario.js";

const rtt = new Trend("rtt", true);
const writesIssued = new Counter("writes_issued");
const deliveries = new Counter("deliveries_observed");

const N_VUS = parseInt(__ENV.BENCH_VUS || "50");
// Per-user boards start at id = SHARED_BOARD_OFFSET + 1. The shared
// "Benchmark Board" lives at id 1; per-user boards from
// `create_per_user_boards` are appended after it.
const SHARED_BOARD_OFFSET = parseInt(__ENV.LOW_SHARING_BOARD_OFFSET || "1");
const STEADY_SECONDS = parseInt(__ENV.LOW_SHARING_STEADY_S || "15");

export const options = {
  summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
  scenarios: {
    isolated: {
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

  const boardId = SHARED_BOARD_OFFSET + __VU;

  const pageRes = http.get(`${BASE_URL}/boards/${boardId}`, { jar });
  check(pageRes, { "page loaded": (r) => r.status === 200 });

  const token = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!token) fail(`could not extract context_token for board ${boardId}`);
  const csrfToken = extractCsrfToken(pageRes.body);

  // Each board seeded by `create_per_user_boards` has 3 cards. Card
  // ids are allocated globally across the seed: shared board's 20
  // cards are 1..20, then 3 per per-user board.
  const cardIdx = 20 + (__VU - 1) * 3 + 1;

  const wsResult = ws.connect(relayWsUrl(WS_URL, token), {}, function (sock) {
    let sendTs = null;

    sock.on("binaryMessage", function () {
      if (sendTs !== null) {
        rtt.add(Date.now() - sendTs);
        deliveries.add(1);
        sendTs = null;
      }
    });
    sock.setInterval(function () {}, 1000);

    // Stabilize: let every VU finish subscribing before any writer fires.
    sock.setTimeout(function () {
      sendTs = Date.now();
      const res = http.post(
        `${BASE_URL}/boards/${boardId}/cards/${cardIdx}`,
        { "card[status]": "in_progress", _method: "patch", authenticity_token: csrfToken },
        { jar, tags: { name: "PATCH_card" } }
      );
      check(res, { "patch 200/204": (r) => r.status >= 200 && r.status < 300 });
      writesIssued.add(1);
    }, 3000);

    sock.setTimeout(function () { sock.close(); }, STEADY_SECONDS * 1000);
  });

  check(wsResult, { "ws connected": (r) => r && r.status === 101 });
}

export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    "results/render-dedup-isolated.json": JSON.stringify(data),
  };
}
