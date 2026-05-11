import { describe, expect, it, vi } from "vitest";

import {
  awaitSubscriptionAck,
  drainPendingDeliveries,
  receiveApplicationMessages,
} from "../delivery_ack.js";

describe("delivery ack", () => {
  it("filters application messages from receiveAll for turbo channels", () => {
    const sub = {
      receiveAll: vi.fn(() => [
        { type: "confirm_subscription" },
        "<turbo-stream>bench-msg:12345:7:2</turbo-stream>",
      ]),
    };

    expect(receiveApplicationMessages(sub, { name: "Turbo::StreamsChannel" }, 1)).toEqual([
      "<turbo-stream>bench-msg:12345:7:2</turbo-stream>",
    ]);
  });

  it("drains application messages from receiveAll", () => {
    const sub = {
      receiveAll: vi.fn(() => [
        { type: "confirm_subscription" },
        "<turbo-stream>bench-msg:1:1:1</turbo-stream>",
      ]),
    };

    expect(drainPendingDeliveries(sub, { name: "Turbo::StreamsChannel" }, 1)).toEqual([
      "<turbo-stream>bench-msg:1:1:1</turbo-stream>",
    ]);
  });

  it("waits for Action Cable subscription acknowledgement when available", () => {
    const sub = {
      ackDuration: vi.fn(() => 12),
    };

    expect(awaitSubscriptionAck(sub)).toBe(12);
    expect(sub.ackDuration).toHaveBeenCalledOnce();
  });
});
