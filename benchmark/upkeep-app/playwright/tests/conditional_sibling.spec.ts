/**
 * M3 idiom #7: D6 conditional sibling (BLOCKED — test.fixme).
 *
 * BLOCKED on Unit 7 v2: per-subscription prior_call_sites storage is not
 * wired (CollectionRendererHook passes prior_call_sites: nil), so the
 * cross-render decline never fires. The pure-function test in
 * signal-rails/test/runtime/rendering/runtime_stream_id_test.rb covers
 * the algorithm; this spec proves the e2e wiring once the store lands.
 *
 * When Unit 7 v2 ships:
 *   1. Remove the test() wrappers below.
 *   2. Confirm the toggle endpoint flips show_archived correctly.
 *   3. Verify the WS frame assertions pass — they are written for the
 *      expected behavior and will catch any regression in tier promotion.
 */

import { test, expect } from "@playwright/test";
import {
  captureWsOutcomes,
  streamInserts,
  streamInsertsForId,
  fragmentUpdates,
} from "./_helpers/ws_frames";

// Use card_id=4 to isolate this fixture's data.
const CARD_ID = 4;
const PAGE_PATH = `/m3/conditional_sibling/${CARD_ID}`;
const TOGGLE_PATH = `/m3/conditional_sibling/${CARD_ID}/toggle`;
const RECENT_PATH = `/m3/sibling_collections/${CARD_ID}/recent`;

test(
  "D6: render with show_archived=true subscribes two streams",
  async ({ page, baseURL }) => {
    // Ensure show_archived starts as true. Prior test runs may have left the
    // card with show_archived=false; toggling here is idempotent if the toggle
    // route flips, so we GET first, count wrappers, and toggle when needed.
    await page.goto(PAGE_PATH);
    const lists = page.locator("#m3-conditional-sibling upkeep-list");
    let count = await lists.count();
    if (count !== 2) {
      await page.request.patch(`${baseURL}${TOGGLE_PATH}`);
      await page.goto(PAGE_PATH);
      count = await lists.count();
    }
    await expect(lists).toHaveCount(2, { timeout: 5_000 });

    const streamIds = await lists.evaluateAll((els) =>
      els.map((el) => el.getAttribute("data-upkeep-stream"))
    );
    expect(streamIds[0]).toMatch(/^rtg_[0-9a-f]{16}$/);
    expect(streamIds[1]).toMatch(/^rtg_[0-9a-f]{16}$/);
    expect(streamIds[0]).not.toBe(streamIds[1]);

    // No WS frame assertion for this test: it verifies initial DOM structure
    // only (two distinct stream wrappers present on load), not a post-mutation
    // delivery. Frame assertions belong on the mutation tests below.
  }
);

test(
  "D6 cross-render decline: toggling show_archived=false collapses to one stream via fragment_replay",
  async ({ page, baseURL }) => {
    // BLOCKED on Unit 7 v2: per-subscription prior_call_sites storage is not
    // wired (CollectionRendererHook passes prior_call_sites: nil), so the
    // cross-render decline never fires. The pure-function test in
    // signal-rails/test/runtime/rendering/runtime_stream_id_test.rb covers
    // the algorithm; this spec proves the e2e wiring once the store lands.

    // Register the WS frame listener before goto — toggling re-renders the page
    // fragment, which may deliver frames immediately.
    const capture = await captureWsOutcomes(page);

    // Start with show_archived=true so two streams are subscribed.
    await page.goto(PAGE_PATH);

    const lists = page.locator("#m3-conditional-sibling upkeep-list");
    await expect(lists).toHaveCount(2, { timeout: 5_000 });

    // Capture the stream id of the second (conditional / archived) wrapper
    // before the toggle removes it.
    const secondStreamId = await lists.nth(1).getAttribute("data-upkeep-stream");

    // Toggle show_archived to false — the conditional stream disappears.
    const toggleResponse = await page.request.patch(`${baseURL}${TOGGLE_PATH}`);
    expect(toggleResponse.status()).toBe(200);

    // After the re-render triggered by the toggle, only one stream remains.
    // The absent stream's prior tier-1 subscription must have been declined
    // (D6 cross-render stability) and replaced with a tier-3 fragment_replay
    // update, not a new tier-1 stream wrapper.
    await expect(lists).toHaveCount(1, { timeout: 10_000 });

    // Verify the surviving stream is the first (unpinned) one, not the archived one.
    const survivingStreamId = await lists.first().getAttribute("data-upkeep-stream");
    expect(survivingStreamId).not.toBe(secondStreamId);

    // WS frame assertion: the toggle re-render must arrive as a fragment-level
    // outcome (diff or replace), not a stream insert for the now-absent stream.
    // No tier-1 stream insert should reference the second stream id after the toggle.
    const outcomes = await capture.outcomes();
    expect(fragmentUpdates(outcomes).length).toBeGreaterThanOrEqual(1);
    if (secondStreamId) {
      expect(streamInsertsForId(outcomes, secondStreamId).length).toBe(0);
    }
  }
);

test(
  "D6: mutating the still-visible stream after toggle delivers a live row",
  async ({ page, baseURL }) => {
    // BLOCKED on Unit 7 v2: per-subscription prior_call_sites storage is not
    // wired (CollectionRendererHook passes prior_call_sites: nil), so the
    // cross-render decline never fires. The pure-function test in
    // signal-rails/test/runtime/rendering/runtime_stream_id_test.rb covers
    // the algorithm; this spec proves the e2e wiring once the store lands.

    // Register the WS frame listener before goto.
    const capture = await captureWsOutcomes(page);

    // Start with show_archived=false so only the unpinned stream is active.
    // Toggle to false if necessary (idempotent — if already false, toggle → true → toggle again).
    await page.goto(PAGE_PATH);

    const lists = page.locator("#m3-conditional-sibling upkeep-list");

    // Ensure we are in the show_archived=false state (one stream).
    const count = await lists.count();
    if (count !== 1) {
      await page.request.patch(`${baseURL}${TOGGLE_PATH}`);
      await expect(lists).toHaveCount(1, { timeout: 10_000 });
    }

    // Capture the surviving stream id before mutation.
    const survivingStreamId = await lists.first().getAttribute("data-upkeep-stream");

    const rows = page.locator("#m3-conditional-sibling [data-testid='comment']");
    const initialCount = await rows.count();

    // Mutate the still-visible stream (unpinned/recent comments on this card).
    const body = `d6-live-${Date.now()}`;
    const response = await page.request.post(
      // POST to sibling_collections recent endpoint for card 4.
      `${baseURL}/m3/sibling_collections/${CARD_ID}/recent`,
      { form: { body } }
    );
    expect(response.status()).toBe(201);

    await expect(rows).toHaveCount(initialCount + 1, { timeout: 10_000 });
    await expect(page.locator(`text=${body}`)).toBeVisible({ timeout: 5_000 });

    // Tier-1 assertion: the still-visible stream delivers its new row as a
    // stream insert (tier-1), not a fragment replay. D6 cross-render decline
    // must not have accidentally demoted the surviving stream.
    const outcomes = await capture.outcomes();
    expect(streamInserts(outcomes).length).toBeGreaterThanOrEqual(1);
    if (survivingStreamId) {
      expect(streamInsertsForId(outcomes, survivingStreamId).length).toBeGreaterThanOrEqual(1);
    }
  }
);
