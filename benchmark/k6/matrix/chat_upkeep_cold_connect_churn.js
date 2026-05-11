// Chat benchmark for Upkeep cold-connect churn.
// Measures login + page + WebSocket + subscribe setup pressure under churn.

import http from "k6/http";
import ws from "k6/ws";
import { check, fail } from "k6";
import { BASE_URL, WS_URL, ROOM_ID, NUM_USERS, buildColdAdmissionOptions } from "../utils/config.js";
import { login } from "../utils/auth.js";
import { findBetween } from "../utils/index.js";
import { buildHandleSummary, relayWsUrl } from "../utils/relay_scenario.js";

// Cold-connect is a capacity gate, not an optimization gate. VUs are
// admitted in hardware-sized waves (see buildColdAdmissionOptions) so
// the ramp tracks PUMA_WORKERS × PUMA_THREADS instead of landing 300
// setups on ~10 slots. Threshold failures at peak mean the host genuinely
// cannot sustain the target — benchmark/bin/run prints a CAPACITY GATE FAILED
// banner on k6 exit 99.
const CHECK_PASS_FLOOR = 0.95;
const HTTP_FAIL_CEILING = 0.05;

export const options = {
  ...buildColdAdmissionOptions(),
  thresholds: {
    checks: [`rate>=${CHECK_PASS_FLOOR}`],
    http_req_failed: [`rate<${HTTP_FAIL_CEILING}`],
  },
};

export default function () {
  const userIdx = (__VU % NUM_USERS) + 1;
  const jar = login(BASE_URL, `user${userIdx}@bench.test`, "benchpass123");

  const pageRes = http.get(`${BASE_URL}/rooms/${ROOM_ID}`, { jar });
  check(pageRes, { "page loaded": (r) => r.status === 200 });
  const token = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!token) fail("could not extract context_token");

  const wsResult = ws.connect(relayWsUrl(WS_URL, token), {}, function (sock) {
    sock.setInterval(function () {}, 1000);
    sock.setTimeout(function () { sock.close(); }, 200);
  });

  check(wsResult, { "ws connected": (r) => r && r.status === 101 });
}

export const handleSummary = buildHandleSummary("results/matrix-chat-cold-upkeep.json");
