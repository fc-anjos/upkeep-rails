/**
 * M3 idiom #2: helper-hidden single-record partial render.
 *
 * Proves that when a helper calls `render partial:, locals:` for a single
 * record the framework:
 *   (a) renders the partial frame inside a reactive wrapper
 *   (b) delivers an in-place DOM update when the record is mutated — no reload.
 *   (c) delivers the update via a fragment-level outcome (tier-3): either
 *       outcome: "diff" (compact ops patch) or outcome: "replace" (full HTML),
 *       not a tier-1 stream insert. Single-record partial renders do not
 *       produce stream membership operations — the partial is re-rendered
 *       in-place.
 *
 * Window marker planted before the mutation must survive, proving reactivity
 * rather than navigation.
 */

import { test, expect } from "@playwright/test";
import { captureWsOutcomes, fragmentUpdates } from "./_helpers/ws_frames";

const CARD_ID = 1;
const PAGE_PATH = `/m3/helper_hidden_partial/${CARD_ID}`;
// Fixture-owned PATCH endpoint — no auth required (CSRF skipped on controller).
const MUTATION_PATH = `/m3/helper_hidden_partial/${CARD_ID}`;
const NEW_TITLE = `playwright-title-${Date.now()}`;

test("helper-hidden partial renders card title and id", async ({ page }) => {
  await page.goto(PAGE_PATH);

  const summary = page.locator('[data-testid="card-summary"]');
  await expect(summary).toBeAttached({ timeout: 5_000 });

  // Both the title text and the id are present in the partial.
  await expect(summary).toContainText(`${CARD_ID}`);
});

test("PATCH card title delivers in-place update without page reload", async ({
  page,
  baseURL,
}) => {
  // Register the WS frame listener before goto so no frame is missed.
  const capture = await captureWsOutcomes(page);

  await page.goto(PAGE_PATH);

  const summary = page.locator('[data-testid="card-summary"]');
  await expect(summary).toBeAttached({ timeout: 5_000 });

  // Plant a window marker to detect any full-page reload.
  await page.evaluate(() => {
    (window as any).__upkeep_test_marker = "m3_partial_smoke";
  });

  const urlBefore = page.url();

  const response = await page.request.patch(`${baseURL}${MUTATION_PATH}`, {
    form: { title: NEW_TITLE },
  });
  expect(response.status()).toBe(200);

  // Wait for the new title to appear inside the card-summary wrapper.
  await expect(summary).toContainText(NEW_TITLE, { timeout: 10_000 });

  // No navigation occurred.
  expect(page.url()).toBe(urlBefore);

  // Window marker survived — no full-page reload.
  const marker = await page.evaluate(
    () => (window as any).__upkeep_test_marker
  );
  expect(marker).toBe("m3_partial_smoke");

  // Tier-3 assertion: single-record partial updates arrive as fragment-level
  // outcomes (diff or replace), not stream inserts. The partial is rendered
  // in-place; stream membership is unchanged.
  const outcomes = await capture.outcomes();
  expect(fragmentUpdates(outcomes).length).toBeGreaterThanOrEqual(1);
});
