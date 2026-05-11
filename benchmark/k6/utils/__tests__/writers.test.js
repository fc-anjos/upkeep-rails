import { describe, expect, it } from "vitest";

import { isWriterVu } from "../writers.js";

describe("writers", () => {
  it("selects every Nth VU starting at 1 by default", () => {
    expect(isWriterVu(1, 10)).toBe(true);
    expect(isWriterVu(10, 10)).toBe(false);
    expect(isWriterVu(11, 10)).toBe(true);
  });

  it("supports shifting the first writer out of the first admission wave", () => {
    expect(isWriterVu(1, 10, 11)).toBe(false);
    expect(isWriterVu(10, 10, 11)).toBe(false);
    expect(isWriterVu(11, 10, 11)).toBe(true);
    expect(isWriterVu(21, 10, 11)).toBe(true);
  });
});
