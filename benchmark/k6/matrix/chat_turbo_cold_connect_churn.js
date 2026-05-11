// Chat benchmark for Turbo cold-connect churn.
// Measures login + page + WebSocket + subscribe setup pressure under churn.

import { ROOM_ID, NUM_USERS, buildColdAdmissionOptions } from "../utils/config.js";
import { establishScenarioContext, disconnectScenarioContext, buildHandleSummary } from "../utils/scenario.js";

const TURBO_BASE = __ENV.BASE_URL || "http://localhost:3001";
const TURBO_WS = __ENV.WS_URL || "ws://localhost:3001/cable";

// Cold-connect is a capacity gate. See chat_upkeep_cold_connect_churn.js
// for rationale — VUs admitted in hardware-sized waves via
// buildColdAdmissionOptions; threshold breaches at peak mean local
// capacity was exhausted, not that Turbo regressed.
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
    baseUrl: TURBO_BASE,
    wsUrl: TURBO_WS,
    numUsers: NUM_USERS,
    iterations: 0,
    pagePath: `/rooms/${ROOM_ID}`,
    channel: {
      name: "Turbo::StreamsChannel",
      tokenAttr: "signed-stream-name",
      paramKey: "signed_stream_name",
    },
  });

  disconnectScenarioContext(ctx);
}

export const handleSummary = buildHandleSummary("results/matrix-chat-cold-turbo.json");
