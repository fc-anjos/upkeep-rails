import { describe, expect, it } from "vitest";

import {
  buildChatBenchmarkBody,
  extractChatBenchmarkMarkers,
} from "../chat_marker.js";

describe("chat benchmark markers", () => {
  it("builds a stable marker body", () => {
    expect(buildChatBenchmarkBody(12345, 7, 2)).toBe("bench-msg:12345:7:2");
  });

  it("extracts every embedded marker timestamp from serialized payloads", () => {
    const payload = JSON.stringify({
      fragments: [
        { id: "messages", html: "<div>bench-msg:12345:7:2</div>" },
        { id: "more", html: "<div>bench-msg:67890:8:3</div>" },
      ],
    });

    expect(extractChatBenchmarkMarkers(payload)).toEqual([
      { marker: "12345:7:2", sendTs: 12345 },
      { marker: "67890:8:3", sendTs: 67890 },
    ]);
  });

  it("ignores payloads without benchmark markers", () => {
    expect(extractChatBenchmarkMarkers('{"fragments":[{"html":"hello"}]}')).toEqual([]);
  });

  it("extracts markers from raw Turbo stream HTML", () => {
    expect(extractChatBenchmarkMarkers("<turbo-stream>bench-msg:12345:7:2</turbo-stream>")).toEqual([
      { marker: "12345:7:2", sendTs: 12345 },
    ]);
  });
});
