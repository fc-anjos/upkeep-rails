// Board no-op diff benchmark for Upkeep.
// Every PATCH sets a card to its current status — guaranteed no-op diff.
// Upkeep should render + diff but suppress WebSocket transmission.
// Measures server-side cost of doing the right thing.

import { check, fail } from "k6";
import http from "k6/http";
import ws from "k6/ws";
import { Trend, Counter } from "k6/metrics";
import { findBetween } from "../utils/index.js";
import { login, extractCsrfToken } from "../utils/auth.js";
import { BASE_URL, WS_URL, BOARD_ID, NUM_USERS, ITERATIONS, buildOptions } from "../utils/config.js";
import { pageRender, buildHandleSummary, relayWsUrl } from "../utils/relay_scenario.js";

const patchLatency = new Trend("patch_latency", true);
const noopPatches = new Counter("noop_patches");
const unexpectedBroadcasts = new Counter("unexpected_broadcasts");

const cardIds = Array.from({ length: 20 }, (_, i) => i + 1);
const statuses = ["todo", "in_progress", "done"];

export const options = buildOptions();

export default function () {
  const userIdx = (__VU % NUM_USERS) + 1;
  const email = `user${userIdx}@bench.test`;

  const jar = login(BASE_URL, email, "benchpass123");

  const renderStart = Date.now();
  const pageRes = http.get(`${BASE_URL}/boards/${BOARD_ID}`, { jar });
  pageRender.add(Date.now() - renderStart);
  check(pageRes, { "page loaded": (r) => r.status === 200 });

  const contextToken = findBetween(pageRes.body, 'data-context-token="', '"');
  if (!contextToken) fail("Could not extract context_token");

  const csrfToken = extractCsrfToken(pageRes.body);
  if (!csrfToken) fail("Could not extract CSRF token");

  const wsResult = ws.connect(relayWsUrl(WS_URL, contextToken), {}, function (sock) {
    let frameCount = 0;
    sock.on("binaryMessage", function () { frameCount += 1; });
    sock.setInterval(function () {}, 1000);

    let i = 0;
    const fire = function () {
      if (i >= ITERATIONS) {
        sock.setTimeout(function () { sock.close(); }, 1000);
        return;
      }
      const writeIndex = i++;
      const cardId = cardIds[writeIndex % cardIds.length];
      const status = statuses[(cardId - 1) % statuses.length];

      const before = frameCount;
      const sendTs = Date.now();
      const res = http.post(
        `${BASE_URL}/boards/${BOARD_ID}/cards/${cardId}`,
        { "card[status]": status, _method: "patch", authenticity_token: csrfToken },
        { jar, tags: { name: "PATCH_noop" } }
      );
      patchLatency.add(Date.now() - sendTs);
      noopPatches.add(1);
      check(res, { "patch ok": (r) => r.status === 200 });

      // Allow 200ms for any leaked broadcast to arrive, then count.
      sock.setTimeout(function () {
        if (frameCount > before) unexpectedBroadcasts.add(frameCount - before);
        sock.setTimeout(fire, 500);
      }, 500);
    };
    sock.setTimeout(fire, 1000);
  });

  check(wsResult, { "ws connected": (r) => r && r.status === 101 });
}

export const handleSummary = buildHandleSummary("results/matrix-board-upkeep-noop.json");
