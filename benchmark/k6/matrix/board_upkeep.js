// Board benchmark for Upkeep (per-user reactive rendering).
// Upkeep renders per subscriber and pushes slot diffs — no thundering herd.
// The page shell stays user-keyed because it carries CSRF/form state, so
// repeated full-page loads do not collapse onto one subscription identity.
// The card fragments are still shareable request-free renders, so card
// updates can deduplicate across viewers of the same board.

import http from "k6/http";
import { Trend } from "k6/metrics";
import { BASE_URL, WS_URL, BOARD_ID, NUM_USERS, ITERATIONS, buildOptions } from "../utils/config.js";
import { runScenario, buildHandleSummary } from "../utils/scenario.js";

const patchLatency = new Trend("patch_latency", true);

const cardIds = Array.from({ length: 20 }, (_, i) => i + 1);
const statuses = ["todo", "in_progress", "done"];

export const options = buildOptions();

export default function () {
  runScenario({
    baseUrl: BASE_URL,
    wsUrl: `${BASE_URL.replace(/^http/, "ws")}/cable`,
    numUsers: NUM_USERS,
    iterations: ITERATIONS,
    pagePath: `/boards/${BOARD_ID}`,
    channel: {
      name: "Upkeep::Rails::Cable::Channel",
      tokenAttr: "data-upkeep-subscription",
      paramKey: "subscription_id",
    },
    writerRatio: parseInt(__ENV.WRITER_RATIO || "20"),
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
  });
}

export const handleSummary = buildHandleSummary("results/matrix-board-upkeep.json");
