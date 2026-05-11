// Board benchmark for Turbo (broadcast_refresh — thundering herd).
// Each subscriber receives a refresh event, then fetches the full page via GET.
// RTT: PATCH card -> refresh event -> simulated GET -> page rendered.

import http from "k6/http";
import { Trend, Counter } from "k6/metrics";
import { BASE_URL, WS_URL, BOARD_ID, NUM_USERS, ITERATIONS, buildOptions } from "../utils/config.js";
import { runScenario, rtt, payloadBytes, broadcastsRcvd, buildHandleSummary } from "../utils/scenario.js";

const patchLatency = new Trend("patch_latency", true);
const refreshLatency = new Trend("refresh_upkeep_ms", true);
const getFetchLatency = new Trend("get_fetch_ms", true);
const turboGets = new Counter("turbo_gets");

const TURBO_BASE = __ENV.BASE_URL || "http://localhost:3001";
const TURBO_WS = __ENV.WS_URL || "ws://localhost:3001/cable";

const cardIds = Array.from({ length: 20 }, (_, i) => i + 1);
const statuses = ["todo", "in_progress", "done"];

function simulateThunderingGet(ctx) {
  const fetchStart = Date.now();
  http.get(`${ctx.baseUrl}/boards/${BOARD_ID}`, {
    jar: ctx.jar,
    tags: { name: "GET_refresh" },
  });
  getFetchLatency.add(Date.now() - fetchStart);
  turboGets.add(1);
}

export const options = buildOptions();

export default function () {
  runScenario({
    baseUrl: TURBO_BASE,
    wsUrl: TURBO_WS,
    numUsers: NUM_USERS,
    iterations: ITERATIONS,
    pagePath: `/boards/${BOARD_ID}`,
    channel: {
      name: "Turbo::StreamsChannel",
      tokenAttr: "signed-stream-name",
      paramKey: "signed_stream_name",
    },
    writerRatio: 20, // 5% writers
    onWrite(ctx, i) {
      const cardId = cardIds[i % cardIds.length];
      const status = statuses[(i + 1) % statuses.length];
      const sendTs = Date.now();

      const res = http.post(
        `${ctx.baseUrl}/boards/${BOARD_ID}/cards/${cardId}`,
        { "card[status]": status, _method: "patch", authenticity_token: ctx.csrfToken },
        { jar: ctx.jar, tags: { name: "PATCH_card" } }
      );
      patchLatency.add(res.timings.duration);
      return { sendTs };
    },
    onWriterReceive(ctx, msg, sendTs) {
      refreshLatency.add(Date.now() - sendTs);
      simulateThunderingGet(ctx);
      rtt.add(Date.now() - sendTs); // end-to-end: PATCH -> GET response
    },
    onReaderReceive(ctx, msgs) {
      for (const msg of msgs) {
        const data = typeof msg === "string" ? msg : JSON.stringify(msg);
        payloadBytes.add(data.length);
        broadcastsRcvd.add(1);
        simulateThunderingGet(ctx);
      }
    },
  });
}

export const handleSummary = buildHandleSummary("results/matrix-board-turbo.json");
