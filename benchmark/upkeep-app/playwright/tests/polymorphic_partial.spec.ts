/**
 * M3 idiom #5: polymorphic / STI partial dispatch.
 *
 * `render @card.comments` with mixed StaffComment / GuestComment subclasses.
 * Rails routes each subclass to its own partial via to_partial_path, so both
 * data-comment-kind values must appear in the rendered HTML.
 *
 * Proves the framework:
 *   (a) renders both STI subclasses with correct kind attributes on first load.
 *   (b) delivers new StaffComment and GuestComment rows live without reload.
 *   (c) delivers each new row via a tier-1 stream insert (outcome: "stream"),
 *       proving the polymorphic collection path is promoted to tier-1.
 */

import { test, expect } from "@playwright/test";
import { captureWsOutcomes, streamInserts } from "./_helpers/ws_frames";

// Use card_id=2 to keep this fixture's comments isolated from idiom #1/#2/#3
// which all target card 1.
const CARD_ID = 2;
const PAGE_PATH = `/m3/polymorphic/${CARD_ID}`;
const MUTATION_PATH = `/m3/polymorphic/${CARD_ID}/comments`;

test("polymorphic collection renders staff and guest comments with correct kind attributes", async ({
  page,
  baseURL,
}) => {
  // Seed one of each kind before loading the page.
  const staffBody = `staff-seed-${Date.now()}`;
  const guestBody = `guest-seed-${Date.now()}`;

  await page.request.post(`${baseURL}${MUTATION_PATH}`, {
    form: { kind: "staff", body: staffBody },
  });
  await page.request.post(`${baseURL}${MUTATION_PATH}`, {
    form: { kind: "guest", body: guestBody },
  });

  await page.goto(PAGE_PATH);

  const staffRows = page.locator('[data-comment-kind="staff"]');
  const guestRows = page.locator('[data-comment-kind="guest"]');

  await expect(staffRows.first()).toBeAttached({ timeout: 5_000 });
  await expect(guestRows.first()).toBeAttached({ timeout: 5_000 });

  await expect(page.locator(`text=${staffBody}`)).toBeVisible();
  await expect(page.locator(`text=${guestBody}`)).toBeVisible();
});

test("live POST of StaffComment delivers new row with data-comment-kind=staff", async ({
  page,
  baseURL,
}) => {
  // Register the WS frame listener before goto so no frame is missed.
  const capture = await captureWsOutcomes(page);

  await page.goto(PAGE_PATH);

  const staffRows = page.locator('[data-comment-kind="staff"]');
  const initialStaffCount = await staffRows.count();

  await page.evaluate(() => {
    (window as any).__upkeep_test_marker = "m3_poly_staff";
  });

  const urlBefore = page.url();
  const staffBody = `live-staff-${Date.now()}`;

  const response = await page.request.post(`${baseURL}${MUTATION_PATH}`, {
    form: { kind: "staff", body: staffBody },
  });
  expect(response.status()).toBe(201);

  await expect(staffRows).toHaveCount(initialStaffCount + 1, {
    timeout: 10_000,
  });
  await expect(page.locator(`text=${staffBody}`)).toBeVisible({ timeout: 5_000 });

  expect(page.url()).toBe(urlBefore);
  const marker = await page.evaluate(
    () => (window as any).__upkeep_test_marker
  );
  expect(marker).toBe("m3_poly_staff");

  // Tier-1 assertion: polymorphic collection inserts arrive as stream
  // outcomes, not fragment replays. M3 promotes collection renders —
  // including polymorphic STI dispatch — to tier-1 delivery.
  const outcomes = await capture.outcomes();
  expect(streamInserts(outcomes).length).toBeGreaterThanOrEqual(1);
});

test("live POST of GuestComment delivers new row with data-comment-kind=guest", async ({
  page,
  baseURL,
}) => {
  // Register the WS frame listener before goto so no frame is missed.
  const capture = await captureWsOutcomes(page);

  await page.goto(PAGE_PATH);

  const guestRows = page.locator('[data-comment-kind="guest"]');
  const initialGuestCount = await guestRows.count();

  await page.evaluate(() => {
    (window as any).__upkeep_test_marker = "m3_poly_guest";
  });

  const urlBefore = page.url();
  const guestBody = `live-guest-${Date.now()}`;

  const response = await page.request.post(`${baseURL}${MUTATION_PATH}`, {
    form: { kind: "guest", body: guestBody },
  });
  expect(response.status()).toBe(201);

  await expect(guestRows).toHaveCount(initialGuestCount + 1, {
    timeout: 10_000,
  });
  await expect(page.locator(`text=${guestBody}`)).toBeVisible({ timeout: 5_000 });

  expect(page.url()).toBe(urlBefore);
  const marker = await page.evaluate(
    () => (window as any).__upkeep_test_marker
  );
  expect(marker).toBe("m3_poly_guest");

  // Tier-1 assertion: polymorphic GuestComment inserts arrive as stream
  // outcomes, not fragment replays.
  const outcomes = await capture.outcomes();
  expect(streamInserts(outcomes).length).toBeGreaterThanOrEqual(1);
});
