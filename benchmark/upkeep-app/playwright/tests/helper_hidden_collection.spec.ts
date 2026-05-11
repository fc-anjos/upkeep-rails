/**
 * M3 idiom smoke spec: helper-hidden collection render reactivity.
 *
 * Proves that when a helper method calls `render partial:, collection:` (the
 * M3 idiom) the framework:
 *   (a) wraps the output in <upkeep-list data-upkeep-stream="rtg_*">
 *   (b) delivers a DOM delta when a new record is created — without a page reload.
 *   (c) delivers the DOM delta via a tier-1 stream insert (outcome: "stream"),
 *       not a tier-3 fragment replay — proving M3 tier promotion.
 *
 * "No page reload" is the load-bearing claim. We plant a window marker before
 * the mutation and assert it survives. A full reload clears window state.
 */

import { test, expect } from "@playwright/test";
import { captureWsOutcomes, streamInserts } from "./_helpers/ws_frames";

// Card id 1 is always present after `db:seed` (BenchmarkSeed resets sequences).
const CARD_ID = 1;
const PAGE_PATH = `/m3/helper_hidden_collection/${CARD_ID}`;
const MUTATION_PATH = `/m3/helper_hidden_collection/${CARD_ID}/comments`;
const COMMENT_BODY = `playwright-m3-${Date.now()}`;

test("helper-hidden collection renders with upkeep-list wrapper", async ({
  page,
  baseURL,
}) => {
  await page.goto(PAGE_PATH);

  // The framework must emit the <upkeep-list> wrapper even for an empty
  // collection (G10 contract). If this fails, CollectionRendererHook or
  // RuntimeStreamId derivation is broken for the helper-hidden call site.
  const list = page.locator("#m3-helper-hidden upkeep-list");
  await expect(list).toBeAttached({ timeout: 5_000 });

  const streamId = await list.getAttribute("data-upkeep-stream");
  expect(streamId).toMatch(/^rtg_[0-9a-f]{16}$/);
});

test("creating a comment via POST delivers a new row without page reload", async ({
  page,
  baseURL,
}) => {
  // Register the WS frame listener before goto so no frame is missed.
  const capture = await captureWsOutcomes(page);

  await page.goto(PAGE_PATH);

  // Count comments already present (may be zero or more from prior runs).
  const commentLocator = page.locator('[data-testid="comment"]');
  const initialCount = await commentLocator.count();

  // Plant a marker on window. A full-page reload clears window state, so
  // the marker surviving the DOM update proves reactivity — not navigation.
  await page.evaluate(() => {
    (window as any).__upkeep_test_marker = "m3_smoke";
  });

  const urlBefore = page.url();

  // Mutate: create a comment for this card. CSRF is skipped on this
  // endpoint (benchmark fixture only).
  const response = await page.request.post(
    `${baseURL}${MUTATION_PATH}`,
    { form: { body: COMMENT_BODY } }
  );
  expect(response.status()).toBe(201);

  // Wait for the new comment row to appear in the live DOM.
  // If this times out, the M3 reactive delivery chain is broken:
  // either the invalidation did not fire, the relay did not deliver,
  // or the client did not patch the DOM.
  await expect(commentLocator).toHaveCount(initialCount + 1, {
    timeout: 10_000,
  });

  // Verify the delivered row contains the exact body we inserted.
  await expect(page.locator(`text=${COMMENT_BODY}`)).toBeVisible({
    timeout: 5_000,
  });

  // No page navigation happened.
  expect(page.url()).toBe(urlBefore);

  // Window marker still present — proves no full-page reload occurred.
  const marker = await page.evaluate(
    () => (window as any).__upkeep_test_marker
  );
  expect(marker).toBe("m3_smoke");

  // Tier-1 assertion: the DOM update must have arrived via a stream insert
  // (outcome: "stream"), not a tier-3 fragment replay. This is M3's
  // load-bearing claim: helper-hidden collection idioms are promoted to
  // tier-1 delivery.
  const outcomes = await capture.outcomes();
  expect(streamInserts(outcomes).length).toBeGreaterThanOrEqual(1);
});
