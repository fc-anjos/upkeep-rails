/**
 * Outcome-capture helpers for upkeep WS delivery assertions.
 *
 * Upkeep dispatches `document.dispatchEvent(new CustomEvent("upkeep:client-outcome", {detail}))`
 * unconditionally from `applyMessage` (lib/upkeep/app/assets/javascripts/upkeep.js).
 * This fires in the page's main JavaScript world for every delivery regardless of
 * transport (WS push or catch-up GET).
 *
 * Detail shape:
 *   { outcome: "diff" | "replace" | "stream" | "catch_up" | "error",
 *     reason?: string, fragmentIds: string[], source: string,
 *     mode?: string, streamId?: string }
 *
 * We install a main-world listener via `page.addInitScript` (which also runs in
 * the main world) and accumulate outcomes into `window.__upkeepCapturedOutcomes`.
 * After the DOM update lands, `capture.outcomes()` reads the array via
 * `page.evaluate`.
 *
 * Only WS-delivered outcomes are relevant for tier assertions:
 *   "stream"  — tier-1: stream insert (collection membership delta).
 *   "diff"    — tier-3: compact ops patch (in-place text/attr change).
 *   "replace" — tier-3: full fragment replacement.
 * "catch_up" is a client-initiated HTTP fallback — not a WS delivery tier.
 *
 * Usage pattern:
 *   const capture = await installOutcomeCapture(page); // before page.goto()
 *   await page.goto(PATH);
 *   // ... mutation ...
 *   await expect(locator).toHaveCount(n, { timeout: 10_000 }); // wait for DOM update
 *   const outcomes = await capture.outcomes();
 *   expect(streamInserts(outcomes).length).toBeGreaterThanOrEqual(1);
 */

import type { Page } from "@playwright/test";

declare global {
  interface Window {
    __upkeepCapturedOutcomes: Array<{ outcome: string; streamId?: string }>;
  }
}

export type CapturedOutcome = {
  outcome: string;
  // stream id; only present for outcome === "stream".
  streamId?: string;
};

export type OutcomeCapture = {
  // Returns the accumulated list of captured outcomes (async — reads from browser).
  outcomes: () => Promise<CapturedOutcome[]>;
};

const KNOWN_OUTCOMES = new Set(["diff", "replace", "stream"]);

/**
 * Install an event listener in the page's main world that captures
 * `upkeep:client-outcome` events. Returns a handle whose `outcomes()`
 * method reads the accumulated list from the browser.
 *
 * Must be called BEFORE page.goto() so the listener is registered before
 * the first WS delivery lands.
 */
export async function installOutcomeCapture(page: Page): Promise<OutcomeCapture> {
  await page.addInitScript(() => {
    window.__upkeepCapturedOutcomes = [];
    document.addEventListener("upkeep:client-outcome", (e: Event) => {
      const detail = (e as CustomEvent).detail;
      if (!detail || typeof detail.outcome !== "string") return;
      // Only capture WS-delivery outcomes; skip catch_up and error.
      const known = ["diff", "replace", "stream"];
      if (!known.includes(detail.outcome)) return;
      window.__upkeepCapturedOutcomes.push({
        outcome: detail.outcome,
        streamId: typeof detail.streamId === "string" ? detail.streamId : undefined,
      });
    });
  });

  return {
    outcomes: async () => {
      return page.evaluate(() => {
        return (window.__upkeepCapturedOutcomes as CapturedOutcome[]) || [];
      });
    },
  };
}

// Specs MUST await this before page.goto(). The init script must be
// registered with Playwright before navigation starts, or events fired
// during page load are lost.
export async function captureWsOutcomes(page: Page): Promise<OutcomeCapture> {
  return installOutcomeCapture(page);
}

// ── Outcome predicates ──────────────────────────────────────────────────

/**
 * Tier-1: stream insert frames. outcome === "stream".
 * These are produced by the collection renderer path (upkeep-list wrappers).
 */
export function streamInserts(outcomes: CapturedOutcome[]): CapturedOutcome[] {
  return outcomes.filter((o) => o.outcome === "stream");
}

/**
 * Tier-3: fragment-level updates. outcome === "diff" | "replace".
 * A "diff" carries compact ops; a "replace" ships full HTML.
 * Both are tier-3 in the M3 taxonomy — fragment replay rather than
 * stream membership patching.
 */
export function fragmentUpdates(outcomes: CapturedOutcome[]): CapturedOutcome[] {
  return outcomes.filter((o) => o.outcome === "diff" || o.outcome === "replace");
}

/**
 * Return stream inserts whose streamId matches the given id.
 */
export function streamInsertsForId(
  outcomes: CapturedOutcome[],
  streamId: string
): CapturedOutcome[] {
  return streamInserts(outcomes).filter((o) => o.streamId === streamId);
}

/**
 * Return stream inserts whose streamId does NOT match the given id.
 * Used to verify sibling stream isolation: no frames land on the
 * un-mutated stream.
 */
export function streamInsertsNotForId(
  outcomes: CapturedOutcome[],
  streamId: string
): CapturedOutcome[] {
  return streamInserts(outcomes).filter((o) => o.streamId !== streamId);
}
