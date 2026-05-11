// Chat benchmark for Turbo (broadcast_append — render once, push to all).
// RTT: POST message -> broadcast_append -> WebSocket push.

import http from "k6/http";
import { sleep } from "k6";
import exec from "k6/execution";
import { Counter, Trend } from "k6/metrics";
import {
  BASE_URL,
  WS_URL,
  ROOM_ID,
  NUM_USERS,
  ITERATIONS,
  buildWarmSteadyStateOptions,
  warmSetupProfile,
  warmSetupAdmissionForVu,
  warmSetupWindowMs,
} from "../utils/config.js";
import {
  establishScenarioContext,
  disconnectScenarioContext,
  runScenarioIterations,
  rtt,
  buildHandleSummary,
} from "../utils/scenario.js";
import { serializeCableApplicationMessage } from "../utils/messages.js";
import {
  buildChatBenchmarkBody,
  extractChatBenchmarkMarkers,
} from "../utils/chat_marker.js";

const postLatency = new Trend("post_latency", true);
const steadyStateSetupLeaks = new Counter("steady_state_setup_leaks");
const observedDeliveryMarkers = new Counter("observed_delivery_markers");

// Turbo apps default to port 3001.
const TURBO_BASE = __ENV.BASE_URL || "http://localhost:3001";
const TURBO_WS = __ENV.WS_URL || "ws://localhost:3001/cable";

const baseOptions = buildWarmSteadyStateOptions();
export const options = {
  ...baseOptions,
  thresholds: {
    ...(baseOptions.thresholds || {}),
    steady_state_setup_leaks: ["count==0"],
    observed_delivery_markers: ["count>0"],
  },
};

export default function () {
  const scenarioStartAt = new Date(exec.scenario.startTime).getTime();
  const measuredPhaseStartsAt = scenarioStartAt + warmSetupWindowMs();
  const setupAdmission = warmSetupAdmissionForVu(__VU);
  const seenMarkers = new Set();

  const recordDeliveryMarkers = function (serialized) {
    if (!serialized) return;

    for (const { marker, sendTs } of extractChatBenchmarkMarkers(serialized)) {
      if (seenMarkers.has(marker)) continue;
      seenMarkers.add(marker);
      observedDeliveryMarkers.add(1);
      rtt.add(Date.now() - sendTs);
    }
  };

  const config = {
    baseUrl: TURBO_BASE,
    wsUrl: TURBO_WS,
    numUsers: NUM_USERS,
    iterations: ITERATIONS,
    pagePath: `/rooms/${ROOM_ID}`,
    channel: {
      name: "Turbo::StreamsChannel",
      tokenAttr: "signed-stream-name",
      paramKey: "signed_stream_name",
    },
    writerRatio: 10,
    writerStartVu: warmSetupProfile().workerCapacity + 1,
    initialJitter: false,
    initialDelaySeconds: setupAdmission.delayMs / 1000,
    onWrite(ctx, i) {
      const sendTs = Date.now();
      const res = http.post(
        `${ctx.baseUrl}/rooms/${ROOM_ID}/messages`,
        { "message[body]": buildChatBenchmarkBody(sendTs, __VU, i), authenticity_token: ctx.csrfToken },
        { jar: ctx.jar, tags: { name: "POST_message" } }
      );
      postLatency.add(res.timings.duration);
      return { sendTs };
    },
    onWriterReceive(ctx, msg, sendTs, serialized) {
      recordDeliveryMarkers(serialized || "");
    },
    onReaderReceive(ctx, msgs) {
      for (const raw of msgs) {
        const serialized = serializeCableApplicationMessage(raw);
        recordDeliveryMarkers(serialized);
      }
    },
  };

  const ctx = establishScenarioContext(config);

  try {
    if (ctx.setupCompletedAt > measuredPhaseStartsAt) {
      steadyStateSetupLeaks.add(1);
      return;
    }

    const waitSeconds = Math.max(0, measuredPhaseStartsAt - Date.now()) / 1000;
    if (waitSeconds > 0) sleep(waitSeconds);

    runScenarioIterations(ctx, config);
  } finally {
    disconnectScenarioContext(ctx);
  }
}

export const handleSummary = buildHandleSummary("results/matrix-chat-warm-turbo.json");
