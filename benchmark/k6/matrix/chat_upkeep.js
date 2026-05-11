// Chat benchmark for Upkeep (per-subscriber reactive rendering).
// RTT: POST message -> server render + diff -> WebSocket push.

import http from "k6/http";
import ws from "k6/ws";
import { check, fail } from "k6";
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
import { login, extractCsrfToken } from "../utils/auth.js";
import { findBetween } from "../utils/index.js";
import {
  buildChatBenchmarkBody,
  extractChatBenchmarkMarkers,
} from "../utils/chat_marker.js";
import { rtt, buildHandleSummary, relayWsUrl } from "../utils/relay_scenario.js";
import { isWriterVu } from "../utils/writers.js";

const postLatency = new Trend("post_latency", true);
const steadyStateSetupLeaks = new Counter("steady_state_setup_leaks");
const observedDeliveryMarkers = new Counter("observed_delivery_markers");

const baseOptions = buildWarmSteadyStateOptions();
export const options = {
  ...baseOptions,
  thresholds: {
    ...(baseOptions.thresholds || {}),
    steady_state_setup_leaks: ["count==0"],
    observed_delivery_markers: ["count>0"],
  },
};

// Convert an ArrayBuffer into a binary-compatible string so JS string
// ops can scan the msgpack payload for the embedded marker. The marker
// is ASCII (`bench-msg:<ts>:<vu>:<i>`) and lives verbatim in the
// rendered HTML; msgpack's str type stores UTF-8, so the byte-by-byte
// latin1 cast preserves the ASCII marker exactly.
function bufferToLatin1(buf) {
  const view = new Uint8Array(buf);
  let s = "";
  for (let i = 0; i < view.length; i += 1) s += String.fromCharCode(view[i]);
  return s;
}

export default function () {
  const scenarioStartAt = new Date(exec.scenario.startTime).getTime();
  const measuredPhaseStartsAt = scenarioStartAt + warmSetupWindowMs();
  const setupAdmission = warmSetupAdmissionForVu(__VU);
  const writerStartVu = warmSetupProfile().workerCapacity + 1;
  const isWriter = isWriterVu(__VU, 10, writerStartVu);
  const seenMarkers = new Set();

  const userIdx = (__VU % NUM_USERS) + 1;
  const jar = login(BASE_URL, `user${userIdx}@bench.test`, "benchpass123");

  const pageRes = http.get(`${BASE_URL}/rooms/${ROOM_ID}`, { jar });
  check(pageRes, { "page loaded": (r) => r.status === 200 });
  const token = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!token) fail("could not extract context_token");
  const csrfToken = extractCsrfToken(pageRes.body);

  const setupCompletedAt = Date.now();
  if (setupCompletedAt > measuredPhaseStartsAt) {
    steadyStateSetupLeaks.add(1);
    return;
  }

  const startDelay = Math.max(0, measuredPhaseStartsAt - Date.now());

  const wsResult = ws.connect(relayWsUrl(WS_URL, token), {}, function (sock) {
    sock.on("binaryMessage", function (data) {
      const serialized = bufferToLatin1(data);
      for (const { marker, sendTs } of extractChatBenchmarkMarkers(serialized)) {
        if (seenMarkers.has(marker)) continue;
        seenMarkers.add(marker);
        observedDeliveryMarkers.add(1);
        rtt.add(Date.now() - sendTs);
      }
    });
    sock.setInterval(function () {}, 1000);

    if (isWriter) {
      let i = 0;
      const fire = function () {
        if (i >= ITERATIONS) {
          sock.setTimeout(function () { sock.close(); }, 2000);
          return;
        }
        const writeIndex = i++;
        const sendTs = Date.now();
        const res = http.post(
          `${BASE_URL}/rooms/${ROOM_ID}/messages`,
          { "message[body]": buildChatBenchmarkBody(sendTs, __VU, writeIndex), authenticity_token: csrfToken },
          { jar, tags: { name: "POST_message" } }
        );
        postLatency.add(res.timings.duration);
        sock.setTimeout(fire, 500);
      };
      sock.setTimeout(fire, startDelay + 500);
    } else {
      sock.setTimeout(function () { sock.close(); }, startDelay + ITERATIONS * 500 + 5000);
    }
  });

  check(wsResult, { "ws connected": (r) => r && r.status === 101 });
}

export const handleSummary = buildHandleSummary("results/matrix-chat-warm-upkeep.json");
