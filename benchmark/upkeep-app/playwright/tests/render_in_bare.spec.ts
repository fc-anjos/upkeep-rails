/**
 * M3 idiom #3: `render(SomeRenderable.new)` bare-arg (RenderingHelper path).
 *
 * CardCountSummary responds to render_in(view_context) and emits a div with
 * the comment count. Proves the framework:
 *   (a) renders the component output inside a reactive wrapper
 *   (b) increments the displayed count when a new comment is added — no reload.
 *   (c) delivers the count update via a fragment-level outcome (tier-3): the
 *       component is re-rendered in-place, not via stream membership.
 *
 * Mutation fires via POST to the existing helper_hidden_collection comment
 * endpoint, which appends a plain Comment to the same card.
 */

import { test, expect } from "@playwright/test";
import { captureWsOutcomes, fragmentUpdates } from "./_helpers/ws_frames";

const CARD_ID = 1;
const PAGE_PATH = `/m3/render_in_bare/${CARD_ID}`;
// Reuse the existing comment-creation endpoint (plain Comment, same card).
const MUTATION_PATH = `/m3/helper_hidden_collection/${CARD_ID}/comments`;

test("render_in component renders initial comment count", async ({ page }) => {
  await page.goto(PAGE_PATH);

  const summary = page.locator('[data-testid="card-count-summary"]');
  await expect(summary).toBeAttached({ timeout: 5_000 });

  // The text must mention the card id and the word "comments".
  await expect(summary).toContainText(`Card ${CARD_ID}`);
  await expect(summary).toContainText("comments");
});

test("adding a comment increments the count without page reload", async ({
  page,
  baseURL,
}) => {
  // Register the WS frame listener before goto so no frame is missed.
  const capture = await captureWsOutcomes(page);

  await page.goto(PAGE_PATH);

  const summary = page.locator('[data-testid="card-count-summary"]');
  await expect(summary).toBeAttached({ timeout: 5_000 });

  // Read the current count text, e.g. "Card 1 has 3 comments".
  const initialText = await summary.innerText();
  const initialCount = parseInt(initialText.match(/has (\d+) comments/)![1], 10);

  // Plant a window marker.
  await page.evaluate(() => {
    (window as any).__upkeep_test_marker = "m3_render_in_smoke";
  });

  const urlBefore = page.url();

  const response = await page.request.post(`${baseURL}${MUTATION_PATH}`, {
    form: { body: `render-in-test-${Date.now()}` },
  });
  expect(response.status()).toBe(201);

  // Wait for the count to increment to initialCount + 1.
  await expect(summary).toContainText(`has ${initialCount + 1} comments`, {
    timeout: 10_000,
  });

  // No navigation.
  expect(page.url()).toBe(urlBefore);

  // Window marker survived — proves no full-page reload.
  const marker = await page.evaluate(
    () => (window as any).__upkeep_test_marker
  );
  expect(marker).toBe("m3_render_in_smoke");

  // Tier-3 assertion: render_in component updates arrive as fragment-level
  // outcomes (diff or replace). The component re-renders its fragment
  // in-place; no stream membership operation is expected.
  const outcomes = await capture.outcomes();
  expect(fragmentUpdates(outcomes).length).toBeGreaterThanOrEqual(1);
});
