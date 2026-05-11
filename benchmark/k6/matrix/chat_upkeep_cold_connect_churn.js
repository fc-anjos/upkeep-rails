// Chat benchmark for Upkeep cold-connect churn.
// Measures login + page + WebSocket + subscribe setup pressure under churn.

import { BASE_URL, ROOM_ID, NUM_USERS, buildColdAdmissionOptions } from "../utils/config.js";
import { establishScenarioContext, disconnectScenarioContext, buildHandleSummary } from "../utils/scenario.js";

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
  const ctx = establishScenarioContext({
    baseUrl: BASE_URL,
    wsUrl: `${BASE_URL.replace(/^http/, "ws")}/cable`,
    numUsers: NUM_USERS,
    iterations: 0,
    pagePath: `/rooms/${ROOM_ID}`,
    channel: {
      name: "Upkeep::Rails::Cable::Channel",
      tokenAttr: "data-upkeep-subscription",
      paramKey: "subscription_id",
    },
  });

  disconnectScenarioContext(ctx);
}

export const handleSummary = buildHandleSummary("results/matrix-chat-cold-upkeep.json");
