import { describe, expect, it } from "vitest";

import { serializeCableApplicationMessage } from "../messages.js";

describe("messages", () => {
  it("serializes Turbo string frames without forcing object payloads", () => {
    const raw = "<turbo-stream>bench-msg:12345:7:2</turbo-stream>";

    expect(serializeCableApplicationMessage(raw)).toBe(raw);
  });

  it("serializes nested Action Cable message objects to their application payload", () => {
    expect(
      serializeCableApplicationMessage({
        message: {
          mid: "m_1",
          outcome: "replace",
          fragments: [{ id: "messages", html: "<div>bench-msg:12345:7:2</div>" }],
        },
      })
    ).toBe(
      JSON.stringify({
        mid: "m_1",
        outcome: "replace",
        fragments: [{ id: "messages", html: "<div>bench-msg:12345:7:2</div>" }],
      })
    );
  });
});
