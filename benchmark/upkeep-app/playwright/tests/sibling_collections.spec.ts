/**
 * M3 idiom #6: sibling collections — same parent, same partial, same `as`,
 * distinguished only by call site.
 *
 * Two helper calls under the same @card each produce a distinct upkeep-list
 * wrapper. The D5 stream-id derivation must produce different ids for the two
 * call sites so mutations to one scope never bleed into the other.
 *
 * Proves:
 *   (a) #m3-pinned and #m3-recent each contain exactly one <upkeep-list>
 *       with distinct data-upkeep-stream values.
 *   (b) A pinned comment appears in #m3-pinned only — delivered via a stream
 *       insert targeting the pinned stream id, not the recent stream id.
 *   (c) A recent comment appears in #m3-recent only — delivered via a stream
 *       insert targeting the recent stream id, not the pinned stream id.
 */

import { test, expect } from "@playwright/test";
import {
  captureWsOutcomes,
  streamInserts,
  streamInsertsForId,
  streamInsertsNotForId,
} from "./_helpers/ws_frames";

// Use card_id=3 to keep this fixture's comments isolated.
const CARD_ID = 3;
const PAGE_PATH = `/m3/sibling_collections/${CARD_ID}`;
const PINNED_PATH = `/m3/sibling_collections/${CARD_ID}/pinned`;
const RECENT_PATH = `/m3/sibling_collections/${CARD_ID}/recent`;

test("page has two upkeep-list wrappers with distinct stream ids", async ({
  page,
}) => {
  await page.goto(PAGE_PATH);

  const pinnedList = page.locator("#m3-pinned upkeep-list");
  const recentList = page.locator("#m3-recent upkeep-list");

  await expect(pinnedList).toBeAttached({ timeout: 5_000 });
  await expect(recentList).toBeAttached({ timeout: 5_000 });

  const pinnedStream = await pinnedList.getAttribute("data-upkeep-stream");
  const recentStream = await recentList.getAttribute("data-upkeep-stream");

  expect(pinnedStream).toMatch(/^rtg_[0-9a-f]{16}$/);
  expect(recentStream).toMatch(/^rtg_[0-9a-f]{16}$/);
  // D5: the two call sites produce distinct stream ids.
  expect(pinnedStream).not.toBe(recentStream);
});

test("posting a pinned comment appears in #m3-pinned only", async ({
  page,
  baseURL,
}) => {
  // Register the WS frame listener before goto so no frame is missed.
  const capture = await captureWsOutcomes(page);

  await page.goto(PAGE_PATH);

  await expect(page.locator("#m3-pinned upkeep-list")).toBeAttached({
    timeout: 5_000,
  });

  // Read the stream ids from the DOM before mutating.
  const pinnedStream = await page
    .locator("#m3-pinned upkeep-list")
    .getAttribute("data-upkeep-stream");
  const recentStream = await page
    .locator("#m3-recent upkeep-list")
    .getAttribute("data-upkeep-stream");

  const pinnedRows = page.locator("#m3-pinned [data-testid='comment']");
  const recentRows = page.locator("#m3-recent [data-testid='comment']");

  const initialPinnedCount = await pinnedRows.count();
  const initialRecentCount = await recentRows.count();

  const body = `pinned-${Date.now()}`;
  const response = await page.request.post(`${baseURL}${PINNED_PATH}`, {
    form: { body },
  });
  expect(response.status()).toBe(201);

  // Row appears in pinned stream.
  await expect(pinnedRows).toHaveCount(initialPinnedCount + 1, {
    timeout: 10_000,
  });
  await expect(page.locator("#m3-pinned").getByText(body)).toBeVisible({
    timeout: 5_000,
  });

  // Recent stream unchanged.
  await expect(recentRows).toHaveCount(initialRecentCount, { timeout: 2_000 });

  // Tier-1 assertion: the pinned insert arrived as a stream outcome.
  const outcomes = await capture.outcomes();
  expect(streamInserts(outcomes).length).toBeGreaterThanOrEqual(1);

  // Stream isolation: at least one stream insert targets the pinned stream id,
  // and no stream insert targets the recent stream id during this window.
  if (pinnedStream && recentStream) {
    expect(streamInsertsForId(outcomes, pinnedStream).length).toBeGreaterThanOrEqual(1);
    expect(
      streamInsertsNotForId(outcomes, pinnedStream)
        .filter((o) => o.streamId === recentStream).length
    ).toBe(0);
  }
});

test("posting a recent comment appears in #m3-recent only", async ({
  page,
  baseURL,
}) => {
  // Register the WS frame listener before goto so no frame is missed.
  const capture = await captureWsOutcomes(page);

  await page.goto(PAGE_PATH);

  await expect(page.locator("#m3-recent upkeep-list")).toBeAttached({
    timeout: 5_000,
  });

  // Read the stream ids from the DOM before mutating.
  const pinnedStream = await page
    .locator("#m3-pinned upkeep-list")
    .getAttribute("data-upkeep-stream");
  const recentStream = await page
    .locator("#m3-recent upkeep-list")
    .getAttribute("data-upkeep-stream");

  const pinnedRows = page.locator("#m3-pinned [data-testid='comment']");
  const recentRows = page.locator("#m3-recent [data-testid='comment']");

  const initialPinnedCount = await pinnedRows.count();
  const initialRecentCount = await recentRows.count();

  const body = `recent-${Date.now()}`;
  const response = await page.request.post(`${baseURL}${RECENT_PATH}`, {
    form: { body },
  });
  expect(response.status()).toBe(201);

  // Row appears in recent stream.
  await expect(recentRows).toHaveCount(initialRecentCount + 1, {
    timeout: 10_000,
  });
  await expect(page.locator("#m3-recent").getByText(body)).toBeVisible({
    timeout: 5_000,
  });

  // Pinned stream unchanged.
  await expect(pinnedRows).toHaveCount(initialPinnedCount, { timeout: 2_000 });

  // Tier-1 assertion: the recent insert arrived as a stream outcome.
  const outcomes = await capture.outcomes();
  expect(streamInserts(outcomes).length).toBeGreaterThanOrEqual(1);

  // Stream isolation: at least one stream insert targets the recent stream id,
  // and no stream insert targets the pinned stream id during this window.
  if (pinnedStream && recentStream) {
    expect(streamInsertsForId(outcomes, recentStream).length).toBeGreaterThanOrEqual(1);
    expect(
      streamInsertsNotForId(outcomes, recentStream)
        .filter((o) => o.streamId === pinnedStream).length
    ).toBe(0);
  }
});
